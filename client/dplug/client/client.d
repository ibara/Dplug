/*
Cockos WDL License

Copyright (C) 2005 - 2015 Cockos Incorporated
Copyright (C) 2015 - 2017 Auburn Sounds

Portions copyright other contributors, see each source file for more information

This software is provided 'as-is', without any express or implied warranty.  In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.
1. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
1. This notice may not be removed or altered from any source distribution.
*/

/// Base client implementation. Every plugin format implementation hold a `Client` member.
module dplug.client.client;

import core.atomic;
import core.stdc.string;
import core.stdc.stdio;
import core.stdc.stdlib: free;

import dplug.core.nogc;
import dplug.core.math;
import dplug.core.vec;

import dplug.client.params;
import dplug.client.preset;
import dplug.client.midi;
import dplug.client.graphics;
import dplug.client.daw;


enum PluginFormat
{
    vst2,
    vst3,
    aax,
    auv2,
    lv2
}


/// A plugin client can send commands to the host.
/// This interface is injected after the client creation though.
interface IHostCommand
{
nothrow @nogc:

    /// Notifies the host that editing of a parameter has begun from UI side.
    void beginParamEdit(int paramIndex);

    /// Notifies the host that a parameter was edited from the UI side.
    /// This enables the host to record automation.
    /// It is illegal to call `paramAutomate` outside of a `beginParamEdit`/`endParamEdit` pair.
    void paramAutomate(int paramIndex, float value);

    /// Notifies the host that editing of a parameter has finished from UI side.
    void endParamEdit(int paramIndex);

    /// Requests to the host a resize of the plugin window's PARENT window, given logical pixels of plugin window.
    ///
    /// Note: UI widgets and plugin format clients have different coordinate systems.
    ///
    /// Params:
    ///     width New width of the plugin, in logical pixels.
    ///     height New height of the plugin, in logical pixels.
    /// Returns: `true` if the host parent window has been resized.
    bool requestResize(int widthLogicalPixels, int heightLogicalPixels);

    /// Report the identied host name (DAW).
    /// MAYDO: not available for LV2.
    DAW getDAW();

    /// Gets the plugin format used at runtime. Version identifier may not be enough in the future, in case of 
    /// unity builds.
    PluginFormat getPluginFormat();
}

// Plugin version in major.minor.patch form.
struct PluginVersion
{
nothrow:
@nogc:
    int major;
    int minor;
    int patch;

    int toVSTVersion() pure const
    {
        assert(major < 10 && minor < 10 && patch < 10);
        return major * 1000 + minor * 100 + patch*10;
    }

    int toAUVersion() pure const
    {
        assert(major < 256 && minor < 256 && patch < 256);
        return (major << 16) | (minor << 8) | patch;
    }

    int toAAXPackageVersion() pure const
    {
        // For AAX, considered binary-compatible unless major version change
        return major;
    }

    void toVST3VersionString(char* outBuffer, int bufLength) const
    {
        snprintf(outBuffer, bufLength, "%d.%d.%d", major, minor, patch);

        // DigitalMars's snprintf doesn't always add a terminal zero
        if (bufLength > 0)
            outBuffer[bufLength-1] = '\0';
    }
}


// Statically known features of the plugin.
// There is some default for explanation purpose, but you really ought to override them all.
// Most of it is redundant with plugin.json, in the future the JSON will be parsed instead.
struct PluginInfo
{
    string vendorName = "Witty Audio";

    /// A four char vendor "unique" ID
    char[4] vendorUniqueID = "Wity";

    /// The vendor email adress for support. Can be null.
    string vendorSupportEmail = null;

    /// Plugin name.
    string pluginName = "Destructatorizer";

    /// Plugin web page. Can be null.
    string pluginHomepage = null;

    /// Used for both VST and AU.
    /// In AU it is namespaced by the manufacturer. In VST it
    /// should be unique. While it seems no VST host use this
    /// ID as a unique way to identify a plugin, common wisdom
    /// is to try to get a sufficiently random one.
    char[4] pluginUniqueID = "WiDi";

    // Plugin version information.
    // It's important that the version you fill at runtime is identical to the
    // one in `plugin.json` else you won't pass AU validation.
    //
    // Note: For AU, 0.x.y is supposed to mean "do not cache", however it is
    //       unknown what it actually changes. AU caching hasn't caused any problem
    //       and can probably be ignored.
    PluginVersion publicVersion = PluginVersion(0, 0, 0);

    /// True if the plugin has a graphical UI. Easy way to disable it.
    bool hasGUI = false;

    /// True if the plugin "is a synth". This has only a semantic effect.
    bool isSynth = false;

    /// True if the plugin should receive MIDI events.
    /// Warning: receiving MIDI forces you to call `getNextMidiMessages`
    /// with the right number of `frames`, every buffer.
    bool receivesMIDI = false;

    /// Used for being at the right place in list of plug-ins.
    PluginCategory category;

    /// Used as name of the bundle in VST.
    string VSTBundleIdentifier;

    /// Used as name of the bundle in AU.
    string AUBundleIdentifier;

    /// Used as name of the bundle in AAX.
    string AAXBundleIdentifier;
}

/// This allows to write things life tempo-synced LFO.
struct TimeInfo
{
    /// BPM
    double tempo = 120;

    /// Current time from the beginning of the song in samples.
    long timeInSamples = 0;

    /// Whether the host sequencer is currently playing
    bool hostIsPlaying;
}

/// Describe a combination of input channels count and output channels count
struct LegalIO
{
    int numInputChannels;
    int numOutputChannels;
}

/// This is the interface used by the GUI, to reduce coupling and avoid exposing the whole of `Client` to it.
/// It should eventually allows to supersede/hide IHostCommand.
interface IClient
{
nothrow:
@nogc:
    /// Requests a resize of the plugin window, notifying the host.
    /// Returns: `true` if succeeded.
    ///
    /// Params:
    ///     width New width of the plugin, in logical pixels.
    ///     height New height of the plugin, in logical pixels.
    bool requestResize(int widthLogicalPixels, int heightLogicalPixels);

    /// Report the identied host name (DAW).
    DAW getDAW();

    /// Gets the plugin format used at runtime. Version identifier may not be enough in the future, in case of 
    /// unity builds.
    PluginFormat getPluginFormat();
}

/// Plugin interface, from the client point of view.
/// This client has no knowledge of thread-safety, it must be handled externally.
/// User plugins derivate from this class.
/// Plugin formats wrappers owns one dplug.plugin.Client as a member.
class Client : IClient
{
public:
nothrow:
@nogc:

    this()
    {
        _info = buildPluginInfo();

        // Create legal I/O combinations
        _legalIOs = buildLegalIO();

        // Create parameters.
        _params = buildParameters();

        // Check parameter consistency
        // This avoid mistake when adding/reordering parameters in a plugin.
        foreach(size_t i, Parameter param; _params)
        {
            // If you fail here, this means your buildParameter() override is incorrect.
            // Check the values of the index you're giving.
            // They should be 0, 1, 2, ..., N-1
            // Maybe you have duplicated a line or misordered them.
            assert(param.index() == i);

            // Sets owner reference.
            param.setClientReference(this);
        }

        // Create presets
        _presetBank = mallocNew!PresetBank(this, buildPresets());


        _maxFramesInProcess = maxFramesInProcess();

        _maxInputs = 0;
        _maxOutputs = 0;
        foreach(legalIO; _legalIOs)
        {
            if (_maxInputs < legalIO.numInputChannels)
                _maxInputs = legalIO.numInputChannels;
            if (_maxOutputs < legalIO.numOutputChannels)
                _maxOutputs = legalIO.numOutputChannels;
        }

        _midiQueue = makeMidiQueue();
    }

    ~this()
    {
        // Destroy graphics
        if (_graphics !is null)
        {
            // Acquire _graphicsIsAvailable forever
            // so that it's the last time the audio uses it,
            // and we can wait for its exit in _graphics destructor
            while(!cas(&_graphicsIsAvailable, true, false))
            {
                // MAYDO: relax CPU
            }
            _graphics.destroyFree();
        }

        // Destroy presets
        _presetBank.destroyFree();

        // Destroy parameters
        foreach(p; _params)
            p.destroyFree();
        _params.freeSlice();
        _legalIOs.freeSlice();
    }

    final int maxInputs() pure const nothrow @nogc
    {
        return _maxInputs;
    }

    final int maxOutputs() pure const nothrow @nogc
    {
        return _maxOutputs;
    }

    /// Returns: Array of parameters.
    final inout(Parameter[]) params() inout nothrow @nogc
    {
        return _params;
    }

    /// Returns: Array of legal I/O combinations.
    final LegalIO[] legalIOs() nothrow @nogc
    {
        return _legalIOs;
    }

    /// Returns: true if the following I/O combination is a legal one.
    ///          < 0 means "do not check"
    final bool isLegalIO(int numInputChannels, int numOutputChannels) pure const nothrow @nogc
    {
        foreach(io; _legalIOs)
            if  ( ( (numInputChannels < 0)
                    ||
                    (io.numInputChannels == numInputChannels) )
                  &&
                  ( (numOutputChannels < 0)
                    ||
                    (io.numOutputChannels == numOutputChannels) )
                )
                return true;

        return false;
    }

    /// Returns: Array of presets.
    final PresetBank presetBank() nothrow @nogc
    {
        return _presetBank;
    }

    /// Returns: The parameter indexed by index.
    final inout(Parameter) param(int index) inout nothrow @nogc
    {
        return _params.ptr[index];
    }

    /// Returns: true if index is a valid parameter index.
    final bool isValidParamIndex(int index) const nothrow @nogc
    {
        return index >= 0 && index < _params.length;
    }

    /// Returns: true if index is a valid input index.
    final bool isValidInputIndex(int index) nothrow @nogc
    {
        return index >= 0 && index < maxInputs();
    }

    /// Returns: true if index is a valid output index.
    final bool isValidOutputIndex(int index) nothrow @nogc
    {
        return index >= 0 && index < maxOutputs();
    }

    /// Note: openGUI, getGUISize, getGraphics and closeGUI are guaranteed
    /// synchronized by the client implementation
    /// Only allowed for client implementation.
    final void* openGUI(void* parentInfo, void* controlInfo, GraphicsBackend backend) nothrow @nogc
    {
        createGraphicsLazily();
        assert(_hostCommand !is null);
        return (cast(IGraphics)_graphics).openUI(parentInfo, controlInfo, this, backend);
    }

    /// Only allowed for client implementation.
    final bool getGUISize(int* widthLogicalPixels, int* heightLogicalPixels) nothrow @nogc
    {
        createGraphicsLazily();
        auto graphics = (cast(IGraphics)_graphics);
        if (graphics)
        {
            graphics.getGUISize(widthLogicalPixels, heightLogicalPixels);
            return true;
        }
        else
            return false;
    }

    /// Close the plugin UI if one was opened.
    /// Note: OBS Studio will happily call effEditClose without having called effEditOpen.
    /// Only allowed for client implementation.
    final void closeGUI() nothrow @nogc
    {
        auto graphics = (cast(IGraphics)_graphics);
        if (graphics)
        {
            graphics.closeUI();
        }
    }

    /// This creates the GUIGraphics object lazily, and return it without synchronization.
    /// Only allowed for client implementation.
    final IGraphics getGraphics()
    {
        createGraphicsLazily();
        return (cast(IGraphics)_graphics);
    }

    // This should be called only by a client implementation.
    void setParameterFromHost(int index, float value) nothrow @nogc
    {
        param(index).setFromHost(value);
    }

    /// Override if you create a plugin with UI.
    /// The returned IGraphics must be allocated with `mallocNew`.
    /// `plugin.json` needs to have a "hasGUI" key equal to true, else this callback is never called.
    IGraphics createGraphics() nothrow @nogc
    {
        return null;
    }

    /// Getter for the IGraphics interface
    /// This is intended ONLY for the audio thread inside processing and has acquire semantics.
    /// Not reentrant! You can't call this twice without a graphicsRelease first.
    /// THIS CAN RETURN NULL EVEN AFTER HAVING RETURNED NON-NULL AT ONE POINT.
    /// Returns: null if feedback from audio thread is not welcome.
    final IGraphics graphicsAcquire() nothrow @nogc
    {
        if (cas(&_graphicsIsAvailable, true, false)) // exclusive, since there is only one audio thread normally
            return _graphics;
        else
            return null;
    }

    /// Mirror function to release the IGraphics from the audio-thread.
    /// Do not call if graphicsAcquire() returned `null`.
    final void graphicsRelease() nothrow @nogc
    {
        // graphicsAcquire should have been called before
        // MAYDO: which memory order here? Don't looks like we need a barrier.
        atomicStore(_graphicsIsAvailable, true);
    }

    // Getter for the IHostCommand interface
    final IHostCommand hostCommand() nothrow @nogc
    {
        return _hostCommand;
    }

    /// Override to clear state (eg: resize and clear delay lines) and allocate buffers.
    /// Note: `reset` should not be called directly by plug-in format implementations. Use `resetFromHost` if you write a new client.
    abstract void reset(double sampleRate, int maxFrames, int numInputs, int numOutputs) nothrow @nogc;

    /// Override to set the plugin latency in samples.
    /// Plugin latency can depend on `sampleRate` but no other value.
    /// If you want your latency to depend on a `Parameter` your only choice is to
    /// pessimize the needed latency and compensate in the process callback.
    /// Returns: Plugin latency in samples.
    /// Note: this can absolutely be called before `reset` was called, be prepared.
    int latencySamples(double sampleRate) nothrow @nogc
    {
        return 0; // By default, no latency introduced by plugin
    }

    /// Override to set the plugin tail length in seconds.
    /// This is the amount of time before silence is reached with a silent input, on the worst
    /// possible settings.
    /// Returns: Plugin tail size in seconds.
    float tailSizeInSeconds() nothrow @nogc
    {
        // Default: 800ms, which shoukld be safe for most plugins except delay or reverb
        return 0.800f;
    }

    /// Override to declare the maximum number of samples to accept
    /// If greater, the audio buffers will be splitted up.
    /// This splitting have several benefits:
    /// - help allocating temporary audio buffers on the stack
    /// - keeps memory usage low and reuse it
    /// - allow faster-than-buffer-size parameter changes
    /// Returns: Maximum number of samples
    int maxFramesInProcess() nothrow @nogc
    {
        return 0; // default returns 0 which means "do not split"
    }

    /// Process some audio.
    /// Override to make some noise.
    /// In processAudio you are always guaranteed to get valid pointers
    /// to all the channels the plugin requested.
    /// Unconnected input pins are zeroed.
    /// This callback is the only place you may call `getNextMidiMessages()` (it is
    /// even required for plugins receiving MIDI).
    ///
    /// Number of frames are guaranteed to be less or equal to what the last reset() call said.
    /// Number of inputs and outputs are guaranteed to be exactly what the last reset() call said.
    /// Warning: Do not modify the output pointers!
    abstract void processAudio(const(float*)[] inputs,    // array of input channels
                               float*[] outputs,           // array of output channels
                               int frames,                // number of sample in each input & output channel
                               TimeInfo timeInfo          // time information associated with this signal frame
                               ) nothrow @nogc;

    /// Should only be called in `processAudio`.
    /// This return a slice of MIDI messages corresponding to the next `frames` samples.
    /// Useful if you don't want to process messages every samples, or every split buffer.
    final const(MidiMessage)[] getNextMidiMessages(int frames) nothrow @nogc
    {
        return _midiQueue.getNextMidiMessages(frames);
    }

    /// Returns a new default preset.
    final Preset makeDefaultPreset() nothrow @nogc
    {
        // MAYDO: use mallocSlice for perf
        auto values = makeVec!float();
        foreach(param; _params)
            values.pushBack(param.getNormalizedDefault());

        // Perf: one could avoid malloc to copy those arrays again there
        float[] valuesSlice = values.releaseData;
        Preset result = mallocNew!Preset("Default", valuesSlice);
        free(valuesSlice.ptr);
        return result;
    }

    // Getters for fields in _info

    final bool hasGUI() pure const nothrow @nogc
    {
        return _info.hasGUI;
    }

    final bool isSynth() pure const nothrow @nogc
    {
        return _info.isSynth;
    }

    final bool receivesMIDI() pure const nothrow @nogc
    {
        return _info.receivesMIDI;
    }

    final string vendorName() pure const nothrow @nogc
    {
        return _info.vendorName;
    }

    final char[4] getVendorUniqueID() pure const nothrow @nogc
    {
        return _info.vendorUniqueID;
    }

    final string getVendorSupportEmail() pure const nothrow @nogc
    {
        return _info.vendorSupportEmail;
    }

    final string pluginName() pure const nothrow @nogc
    {
        return _info.pluginName;
    }

    final string pluginHomepage() pure const nothrow @nogc
    {
        return _info.pluginHomepage;
    }

    final PluginCategory pluginCategory() pure const nothrow @nogc
    {
        return _info.category;
    }

    final string VSTBundleIdentifier() pure const nothrow @nogc
    {
        return _info.VSTBundleIdentifier;
    }

    final string AUBundleIdentifier() pure const nothrow @nogc
    {
        return _info.AUBundleIdentifier;
    }

    final string AAXBundleIdentifier() pure const nothrow @nogc
    {
        return _info.AAXBundleIdentifier;
    }

    /// Returns: Plugin "unique" ID.
    final char[4] getPluginUniqueID() pure const nothrow @nogc
    {
        return _info.pluginUniqueID;
    }

    /// Returns: Plugin full name "$VENDOR $PRODUCT"
    final void getPluginFullName(char* p, int bufLength) const nothrow @nogc
    {
        snprintf(p, bufLength, "%.*s %.*s",
                 cast(int)(_info.vendorName.length), _info.vendorName.ptr,
                 cast(int)(_info.pluginName.length), _info.pluginName.ptr);

        // DigitalMars's snprintf doesn't always add a terminal zero
        if (bufLength > 0)
        {
            p[bufLength-1] = '\0';
        }
    }

    /// Returns: Plugin version in x.x.x.x decimal form.
    final PluginVersion getPublicVersion() pure const nothrow @nogc
    {
        return _info.publicVersion;
    }

    deprecated("Use readParam!float() instead.")
    {
        alias readFloatParamValue = readParam!float;
    }

    deprecated("Use readParam!int() instead.")
    {
        alias readIntegerParamValue = readParam!int;
    }

    deprecated("Use readParam!bool() instead.")
    {
        alias readBoolParamValue = readParam!bool;
    }
       
    deprecated("Use readParam!MyEnum() instead.")
        /// Boilerplate function to get the value of an `EnumParameter`, for use in `processAudio`.
        int readEnumParamValue(int paramIndex) nothrow @nogc
        {
            auto p = param(paramIndex);
            assert(cast(EnumParameter)p !is null); // check it's an EnumParameter
            return unsafeObjectCast!EnumParameter(p).valueAtomic();
        }

    /// Boilerplate function to get the value of a `FloatParameter`, for use in `processAudio`.
    final T readParam(T)(int paramIndex) nothrow @nogc
        if (is(T == float))
    {
        auto p = param(paramIndex);
        assert(cast(FloatParameter)p !is null); // check it's a FloatParameter
        return unsafeObjectCast!FloatParameter(p).valueAtomic();
    }

    /// Boilerplate function to get the value of an `IntParameter`, for use in `processAudio`.
    final T readParam(T)(int paramIndex) nothrow @nogc
        if (is(T == int) && !is(T == enum))
    {
        auto p = param(paramIndex);
        assert(cast(IntegerParameter)p !is null); // check it's an IntParameter
        return unsafeObjectCast!IntegerParameter(p).valueAtomic();
    }

    /// Boilerplate function to get the value of an `EnumParameter`, for use in `processAudio`.
    final T readParam(T)(int paramIndex) nothrow @nogc
        if (is(T == enum))
    {
        auto p = param(paramIndex);
        assert(cast(EnumParameter)p !is null); // check it's an EnumParameter
        return cast(T)(unsafeObjectCast!EnumParameter(p).valueAtomic());
    }

    /// Boilerplate function to get the value of a `BoolParameter`,for use in `processAudio`.
    final T readParam(T)(int paramIndex) nothrow @nogc
        if (is(T == bool))
    {
        auto p = param(paramIndex);
        assert(cast(BoolParameter)p !is null); // check it's a BoolParameter
        return unsafeObjectCast!BoolParameter(p).valueAtomic();
    }

    /// For plugin format clients only.
    final void setHostCommand(IHostCommand hostCommand) nothrow @nogc
    {
        _hostCommand = hostCommand;

        // In VST3, for accuracy of parameter automation we choose to split buffers in chunks of maximum 512.
        // This avoids painful situations where parameters could higher precision.
        if (hostCommand.getPluginFormat() == PluginFormat.vst3)
        {
            if (_maxFramesInProcess == 0 || _maxFramesInProcess > 512)
                _maxFramesInProcess = 512;
        }
    }

    /// For plugin format clients only.
    /// Enqueues an incoming MIDI message.
    void enqueueMIDIFromHost(MidiMessage message)
    {
        _midiQueue.enqueue(message);
    }

    /// For plugin format clients only.
    /// Calls processAudio repeatedly, splitting the buffers.
    /// Splitting allow to decouple memory requirements from the actual host buffer size.
    /// There is few performance penalty above 512 samples.
    void processAudioFromHost(float*[] inputs,
                              float*[] outputs,
                              int frames,
                              TimeInfo timeInfo,
                              bool doNotSplit = false, // flag that exist in case the plugin client want to split itself
                              ) nothrow @nogc
    {
        // In debug mode, fill all output audio buffers with `float.nan`.
        // This avoids a plug-in forgetting to fill output buffers, which can happen if you
        // implement silence detection badly.
        // CAUTION: this assumes inputs and outputs buffers do not point into the same memory areas
        debug
        {
            for (int k = 0; k < outputs.length; ++k)
            {
                float* pOut = outputs[k];
                pOut[0..frames] = float.nan;
            }
        }

        if (_maxFramesInProcess == 0 || doNotSplit)
        {
            processAudio(inputs, outputs, frames, timeInfo);
        }
        else
        {
            // Slice audio in smaller parts
            while (frames > 0)
            {
                // Note: the last slice will be smaller than the others
                int sliceLength = frames;
                if (sliceLength > _maxFramesInProcess)
                    sliceLength = _maxFramesInProcess;

                processAudio(inputs, outputs, sliceLength, timeInfo);

                // offset all input buffer pointers
                for (int i = 0; i < cast(int)inputs.length; ++i)
                    inputs[i] = inputs[i] + sliceLength;

                // offset all output buffer pointers
                for (int i = 0; i < cast(int)outputs.length; ++i)
                    outputs[i] = outputs[i] + sliceLength;

                frames -= sliceLength;

                // timeInfo must be updated
                timeInfo.timeInSamples += sliceLength;
            }
            assert(frames == 0);
        }
    }

    /// For plugin format clients only.
    /// Calls `reset()`.
    /// Must be called by the audio thread.
    void resetFromHost(double sampleRate, int maxFrames, int numInputs, int numOutputs) nothrow @nogc
    {
        // Clear outstanding MIDI messages (now invalid)
        _midiQueue.initialize();

        // We potentially give to the client implementation a lower value
        // for the maximum number of frames
        if (_maxFramesInProcess != 0 && _maxFramesInProcess < maxFrames)
            maxFrames = _maxFramesInProcess;

        // Calls the reset virtual call
        reset(sampleRate, maxFrames, numInputs, numOutputs);
    }

    /// For use by plugin format clients. This gives the buffer split size to use.
    /// (0 == no split).
    /// This is useful in the cast the format client wants to split buffers by itself.
    final int getBufferSplitMaxFrames()
    {
        return _maxFramesInProcess;
    }

    // <IClient>
    override bool requestResize(int widthLogicalPixels, int heightLogicalPixels)
    {
        if (_hostCommand is null) 
            return false;

        return _hostCommand.requestResize(widthLogicalPixels, heightLogicalPixels);
    }

    override DAW getDAW()
    {
        assert(_hostCommand !is null);
        return _hostCommand.getDAW();
    }

    override PluginFormat getPluginFormat()
    {
        assert(_hostCommand !is null);
        return _hostCommand.getPluginFormat();
    }

    // </IClient>

protected:

    /// Override this method to implement parameter creation.
    /// This is an optional overload, default implementation declare no parameters.
    /// The returned slice must be allocated with `malloc`/`mallocSlice` and contains
    /// `Parameter` objects created with `mallocEmplace`.
    Parameter[] buildParameters()
    {
        return [];
    }

    /// Override this methods to load/fill presets.
    /// This function must return a slice allocated with `malloc`,
    /// that contains presets crteated with `mallocEmplace`.
    Preset[] buildPresets() nothrow @nogc
    {
        auto presets = makeVec!Preset();
        presets.pushBack( makeDefaultPreset() );
        return presets.releaseData();
    }

    /// Override this method to tell what plugin you are.
    /// Mandatory override, fill the fields with care.
    /// Note: this should not be called by a plugin client implementation directly.
    ///       Access the content of PluginInfo through the various accessors.
    abstract PluginInfo buildPluginInfo();

    /// Override this method to tell which I/O are legal.
    /// The returned slice must be allocated with `malloc`/`mallocSlice`.
    abstract LegalIO[] buildLegalIO();

    IGraphics _graphics;

    // Used as a flag that _graphics can be used (by audio thread or for destruction)
    shared(bool) _graphicsIsAvailable = false;

    // Note: when implementing a new plug-in format, the format wrapper has to call
    // `setHostCommand` and implement `IHostCommand`.
    IHostCommand _hostCommand = null;

    PluginInfo _info;

private:
    Parameter[] _params;

    PresetBank _presetBank;

    LegalIO[] _legalIOs;

    int _maxInputs, _maxOutputs; // maximum number of input/outputs

    // Cache result of maxFramesInProcess(), maximum frame length
    int _maxFramesInProcess;

    // Container for awaiting MIDI messages.
    MidiQueue _midiQueue;

    final void createGraphicsLazily()
    {
        // First GUI opening create the graphics object
        // no need to protect _graphics here since the audio thread
        // does not write to it
        if ( (_graphics is null) && hasGUI())
        {
            // Why is the IGraphics created lazily? This allows to load a plugin very quickly,
            // without opening its logical UI
            IGraphics graphics = createGraphics();

            // Don't forget to override the createGraphics method!
            assert(graphics !is null);

            _graphics = graphics;

            // Now that the UI is fully created, we enable the audio thread to use it
            atomicStore(_graphicsIsAvailable, true);
        }
    }
}

/// Should be called in Client class during compile time
/// to parse a `PluginInfo` from a supplied json file.
PluginInfo parsePluginInfo(string json)
{
    import std.json;
    import std.string;
    import std.conv;

    JSONValue j = parseJSON(json);

    static bool toBoolean(JSONValue value)
    {
        static if (__VERSION__ >= 2087)
        {
            if (value.type == JSONType.true_)
                return true;
            if (value.type == JSONType.false_)
                return false;
        }
        else
        {
            if (value.type == JSON_TYPE.TRUE)
                return true;
            if (value.type == JSON_TYPE.FALSE)
                return false;
        }
        throw new Exception(format("Expected a boolean, got %s instead", value));
    }

    // Check that a string is "x.y.z"
    // FUTURE: support larger integers than 0 to 9 in the string
    static PluginVersion parsePluginVersion(string value)
    {
        bool isDigit(char ch)
        {
            return ch >= '0' && ch <= '9';
        }

        if ( value.length != 5  ||
             !isDigit(value[0]) ||
             value[1] != '.'    ||
             !isDigit(value[2]) ||
             value[3] != '.'    ||
             !isDigit(value[4]))
        {
            throw new Exception("\"publicVersion\" should follow the form x.y.z (eg: \"1.0.0\")");
        }

        PluginVersion ver;
        ver.major = value[0] - '0';
        ver.minor = value[2] - '0';
        ver.patch = value[4] - '0';
        return ver;
    }

    PluginInfo info;
    info.vendorName = j["vendorName"].str;
    info.vendorUniqueID = j["vendorUniqueID"].str;
    info.pluginName = j["pluginName"].str;
    info.pluginUniqueID = j["pluginUniqueID"].str;

    if ("vendorSupportEmail" in j)
        info.vendorSupportEmail= j["vendorSupportEmail"].str;

    if ("pluginHomepage" in j)
        info.pluginHomepage = j["pluginHomepage"].str;

    info.isSynth = toBoolean(j["isSynth"]);
    info.hasGUI = toBoolean(j["hasGUI"]);
    info.receivesMIDI = toBoolean(j["receivesMIDI"]);
    info.publicVersion = parsePluginVersion(j["publicVersion"].str);

    string CFBundleIdentifierPrefix = j["CFBundleIdentifierPrefix"].str;

    string sanitizedName = sanitizeBundleString(info.pluginName);
    info.VSTBundleIdentifier = CFBundleIdentifierPrefix ~ ".vst." ~ sanitizedName;
    info.AUBundleIdentifier = CFBundleIdentifierPrefix ~ ".audiounit." ~ sanitizedName;
    info.AAXBundleIdentifier = CFBundleIdentifierPrefix ~ ".aax." ~ sanitizedName;

    PluginCategory category = parsePluginCategory(j["category"].str);
    if (category == PluginCategory.invalid)
        throw new Exception("Invalid \"category\" in plugin.json. Check out dplug.client.daw for valid values (eg: \"effectDynamics\").");
    info.category = category;

    // See Issue #581.
    // Check that we aren't leaking secrets in this build, through `import("plugin.json")`.
    void checkNotLeakingPassword(string key)
    {
        if (key in j)
        {
            string pwd = j[key].str;
            if (pwd == "!PROMPT")
                return;

            if (pwd.length > 0 && pwd[0] == '$')
                return; // using an envvar

            throw new Exception(
                        "\n*************************** WARNING ***************************\n\n"
                        ~ "  This build is using a plain text password in plugin.json\n"
                        ~ "  This will leak through `import(\"plugin.json\")`\n\n"
                        ~ "  Solutions:\n"
                        ~ "    1. Use environment variables, such as:\n"
                        ~ "           \"iLokPassword\": \"$ILOK_PASSWORD\"\n"
                        ~ "    2. Use the special value \"!PROMPT\", such as:\n"
                        ~ "           \"keyPassword-windows\": \"!PROMPT\"\n\n"
                        ~ "***************************************************************\n");
        }
    }
    checkNotLeakingPassword("keyPassword-windows");
    checkNotLeakingPassword("iLokPassword");

    void checkNotLeakingNoPrompt(string key)
    {
        if (key in j)
        {
            string pwd = j[key].str;
            if (pwd.length > 0 && pwd[0] == '$')
                return; // using an envvar

            throw new Exception(
                        "\n*************************** WARNING ***************************\n\n"
                        ~ "  This build is using a plain text password in plugin.json\n"
                        ~ "  This will leak through `import(\"plugin.json\")`\n\n"
                        ~ "  Solution:\n"
                        ~ "       Use environment variables, such as:\n"
                        ~ "           \"appSpecificPassword-altool\": \"$APP_SPECIFIC_PASSWORD\"\n\n"
                        ~ "***************************************************************\n");
        }
    }
    checkNotLeakingNoPrompt("appSpecificPassword-altool");
    checkNotLeakingNoPrompt("appSpecificPassword-stapler");

    return info;
}

private string sanitizeBundleString(string s) pure
{
    string r = "";
    foreach(dchar ch; s)
    {
        if (ch >= 'A' && ch <= 'Z')
            r ~= ch;
        else if (ch >= 'a' && ch <= 'z')
            r ~= ch;
        else if (ch == '.')
            r ~= ch;
        else
            r ~= "-";
    }
    return r;
}