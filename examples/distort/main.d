/**
Copyright: Guillaume Piolat 2015-2017.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module main;

import std.math;

import dplug.core,
       dplug.client,
       dplug.dsp;

import gui;

// This define entry points for plugin formats, 
// depending on which version identifiers are defined.
mixin(pluginEntryPoints!DistortClient);

enum : int
{
    paramInput,
    paramDrive,
    paramBias,
    paramOutput,
    paramOnOff,
}

/// Example mono/stereo distortion plugin.
final class DistortClient : dplug.client.Client
{
public:
nothrow:
@nogc:

    this()
    {
    }

    ~this()
    {
        _inputRMS.reallocBuffer(0);
        _outputRMS.reallocBuffer(0);
    }

    override PluginInfo buildPluginInfo()
    {
        // Plugin info is parsed from plugin.json here at compile time.
        // Indeed it is strongly recommended that you do not fill PluginInfo 
        // manually, else the information could diverge.
        static immutable PluginInfo pluginInfo = parsePluginInfo(import("plugin.json"));
        return pluginInfo;
    }

    // This is an optional overload, default is zero parameter.
    // Caution when adding parameters: always add the indices
    // in the same order than the parameter enum.
    override Parameter[] buildParameters()
    {
        auto params = makeVec!Parameter();
        params ~= mallocNew!GainParameter(paramInput, "input", 6.0, 0.0);
        params ~= mallocNew!LinearFloatParameter(paramDrive, "drive", "%", 0.0f, 100.0f, 20.0f);
        params ~= mallocNew!LinearFloatParameter(paramBias, "bias", "%", 0.0f, 100.0f, 50.0f);
        params ~= mallocNew!GainParameter(paramOutput, "output", 6.0, 0.0);
        params ~= mallocNew!BoolParameter(paramOnOff, "enabled", true);
        return params.releaseData();
    }

    override LegalIO[] buildLegalIO()
    {
        auto io = makeVec!LegalIO();
        io ~= LegalIO(1, 1);
        io ~= LegalIO(2, 2);
        return io.releaseData();
    }

    // This override is optional, this supports plugin delay compensation in hosts.
    // By default, 0 samples of latency.
    override int latencySamples(double sampleRate) pure const 
    {
        return 0;
    }

    // This override is optional, the default implementation will
    // have one default preset.
    override Preset[] buildPresets()
    {
        auto presets = makeVec!Preset();
        presets ~= makeDefaultPreset();

        static immutable float[] silenceParams = [0.0f, 0.0f, 0.0f, 1.0f, 0];
        presets ~= mallocNew!Preset("Silence", silenceParams);

        static immutable float[] fullOnParams = [1.0f, 1.0f, 0.4f, 1.0f, 0];
        presets ~= mallocNew!Preset("Full-on", fullOnParams);
        return presets.releaseData();
    }

    // This override is also optional. It allows to split audio buffers in order to never
    // exceed some amount of frames at once.
    // This can be useful as a cheap chunking for parameter smoothing.
    // Buffer splitting also allows to allocate statically or on the stack with less worries.
    // It also makes the plugin uses constant memory in case of large buffer sizes.
    // In VST3, parameter automation gets more precise when this value is small.
    override int maxFramesInProcess() const //nothrow @nogc
    {
        return 512;
    }

    override void reset(double sampleRate, int maxFrames, int numInputs, int numOutputs)
    {
        // Clear here any state and delay buffers you might have.
        assert(maxFrames <= 512); // guaranteed by audio buffer splitting

        _sampleRate = sampleRate;

        _levelInput.initialize(sampleRate);
        _levelOutput.initialize(sampleRate);

        _inputRMS.reallocBuffer(maxFrames);
        _outputRMS.reallocBuffer(maxFrames);

        foreach(channel; 0..2)
        {            
            _hpState[channel].initialize();
        }
    }

    override void processAudio(const(float*)[] inputs, float*[]outputs, int frames, TimeInfo info)
    {
        assert(frames <= 512); // guaranteed by audio buffer splitting

        int numInputs = cast(int)inputs.length;
        int numOutputs = cast(int)outputs.length;
        assert(numInputs == numOutputs);

        const float inputGain = convertDecibelToLinearGain(readParam!float(paramInput));
        float drive = readParam!float(paramDrive) * 0.01f;
        float bias = readParam!float(paramBias) * 0.01f;
        const float outputGain = convertDecibelToLinearGain(readParam!float(paramOutput));

        const bool enabled = readParam!bool(paramOnOff);

        if (enabled)
        {
            BiquadCoeff highpassCoeff = biquadRBJHighPass(150, _sampleRate, SQRT1_2);
            for (int chan = 0; chan < numOutputs; ++chan)
            {
                // Distort and put the result in output buffers
                for (int f = 0; f < frames; ++f)
                {
                    const float inputSample = inputGain * 2.0 * inputs[chan][f];

                    // Distort signal
                    const float distorted = tanh(inputSample * drive * 10.0f + bias) * 0.9f;
                    outputs[chan][f] = outputGain * distorted;
                }

                // Highpass to remove bias
                _hpState[chan].nextBuffer(outputs[chan], outputs[chan], frames, highpassCoeff);
            }
        }
        else
        {
            // Bypass mode
            for (int chan = 0; chan < numOutputs; ++chan)
                outputs[chan][0..frames] = inputs[chan][0..frames];
        }

        // Compute feedback for the UI.
        // We take the first channel (left) and process it, then send it to the widgets.
        _levelInput.nextBuffer(inputs[0], _inputRMS.ptr, frames);
        _levelOutput.nextBuffer(outputs[0], _outputRMS.ptr, frames);

        // Update meters from the audio callback.
        if (DistortGUI gui = cast(DistortGUI) graphicsAcquire())
        {
            gui.sendFeedbackToUI(_inputRMS.ptr, _outputRMS.ptr, frames, _sampleRate);
            graphicsRelease();
        }
    }

    override IGraphics createGraphics()
    {
        return mallocNew!DistortGUI(this);
    }

private:
    LevelComputation _levelInput;
    LevelComputation _levelOutput;
    BiquadDelay[2] _hpState;
    float _sampleRate;
    float[] _inputRMS, _outputRMS;
}


/// Sliding dB computation.
/// Simple envelope follower, filters the envelope with 24db/oct lowpass.
struct LevelComputation
{
public:
nothrow:
@nogc:

    void initialize(float samplerate)
    {
        float attackSecs = 0.001;
        float releaseSecs = 0.001;
        float initValue = -140;
        _envelope.initialize(samplerate, attackSecs, releaseSecs, initValue);
    }

    // take audio samples, output RMS values.
    void nextBuffer(const(float)* input, float* output, int frames)
    {
        // Compute squared value
        for(int i = 0; i < frames; ++i)
            output[i] = input[i] * input[i] + 1e-10f; // avoid -inf

        // Take log
        for (int n = 0; n < frames; ++n)
        {
            output[n] = convertLinearGainToDecibel(output[n]);
        }

        _envelope.nextBuffer(output, output, frames);
    }

private:
    AttackReleaseSmoother!float _envelope;
}



