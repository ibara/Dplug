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
/**
    MIDI messages definitions.
*/
module dplug.client.midi;

import std.algorithm.mutation;
import dplug.core.vec;

/// This abstraction is similar to the one in IPlug.
/// For VST raw MIDI messages are passed.
/// For AU MIDI messages gets synthesized.
struct MidiMessage
{
pure:
nothrow:
@nogc:

    this( int offset, ubyte statusByte, ubyte data1, ubyte data2)
    {
        _offset = offset;
        _statusByte = statusByte;
        _data1 = data1;
        _data2 = data2;
    }

    int offset() const
    {
        return _offset;
    }

    /// Midi channels 1 .. 16
    ///
    /// Returns: [0 .. 15]
    int channel() const
    {
        return _statusByte & 0x0F;
    }

    /// Status Type
    ///
    /// See_Also: dplug.client.midi : MidiStatus
    int statusType() const
    {
        return _statusByte >> 4;
    }

    // Status type distinction properties

    bool isChannelAftertouch() const
    {
        return statusType() == MidiStatus.channelAftertouch;
    }

    bool isControlChange() const
    {
        return statusType() == MidiStatus.controlChange;
    }

    /// Checks whether the status type of the message is 'Note On'
    /// _and the velocity value is actually greater than zero_.
    ///
    /// IMPORTANT: As per MIDI 1.0, a 'Note On' event with a velocity
    ///            of zero should be treated like a 'Note Off' event.
    ///            Which is why this function checks velocity > 0.
    ///
    /// See_Also:
    ///     isNoteOff()
    bool isNoteOn() const
    {
        return (statusType() == MidiStatus.noteOn) && (noteVelocity() > 0);
    }

    /// Checks whether the status type of the message is 'Note Off'
    /// or 'Note On' with a velocity of 0.
    ///
    /// IMPORTANT: As per MIDI 1.0, a 'Note On' event with a velocity
    ///            of zero should be treated like a 'Note Off' event.
    ///            Which is why this function checks velocity == 0.
    ///
    ///            Some devices send a 'Note On' message with a velocity
    ///            value of zero instead of a real 'Note Off' message.
    ///            Many DAWs will automatically convert such ones to
    ///            explicit ones, but one cannot rely on this.
    ///
    /// See_Also:
    ///     isNoteOn()
    bool isNoteOff() const
    {
        return (statusType() == MidiStatus.noteOff)
               ||
               ( (statusType() == MidiStatus.noteOn) && (noteVelocity() == 0) );
    }

    /// DO HANDLE THIS. From MIDI Spec:
    ///
    /// "Mutes all sounding notes that were turned on by received Note On messages, and which haven't yet been 
    /// turned off by respective Note Off messages. [...]
    ///
    /// "Note: The difference between this message and All Notes Off is that this message immediately mutes all sound 
    /// on the device regardless of whether the Hold Pedal is on, and mutes the sound quickly regardless of any lengthy 
    /// VCA release times. It's often used by sequencers to quickly mute all sound when the musician presses "Stop" in 
    /// the middle of a song."
    bool isAllSoundsOff() const
    {
        return isControlChange() && (controlChangeControl() == MidiControlChange.allSoundsOff);
    }

    /// DO HANDLE THIS. From MIDI Spec:
    ///
    /// "Turns off all notes that were turned on by received Note On messages, and which haven't yet been turned off 
    /// by respective Note Off messages. [...]
    bool isAllNotesOff() const
    {
        return isControlChange() && (controlChangeControl() == MidiControlChange.allNotesOff);
    }

    bool isPitchBend() const
    {
        return statusType() == MidiStatus.pitchWheel;
    }

    alias isPitchWheel = isPitchBend;

    bool isPolyAftertouch() const
    {
        return statusType() == MidiStatus.polyAftertouch;
    }

    bool isProgramChange() const
    {
        return statusType() == MidiStatus.programChange;
    }

    // Data value properties

    /// Channel pressure
    int channelAftertouch() const
    {
        assert(isChannelAftertouch());
        return _data1;
    }

    /// Number of the changed controller
    MidiControlChange controlChangeControl() const
    {
        assert(isControlChange());
        return cast(MidiControlChange)(_data1);
    }

    /// Controller's new value
    ///
    /// Returns: [1 .. 127]
    int controlChangeValue() const
    {
        assert(isControlChange());
        return _data2;
    }

    /// Controller's new value
    ///
    /// Returns: [0.0 .. 1.0]
    float controlChangeValue0to1() const
    {
        return cast(float)(controlChangeValue()) / 127.0f;
    }

    /// Returns: true = on
    bool controlChangeOnOff() const
    {
        return controlChangeValue() >= 64;
    }

    int noteNumber() const
    {
        assert(isNoteOn() || isNoteOff() || isPolyAftertouch());
        return _data1;
    }

    int noteVelocity() const
    {
        return _data2;
    }

    /// Returns: [-1.0 .. 1.0[
    float pitchBend() const
    {
        assert(isPitchBend());
        immutable int iVal = (_data2 << 7) + _data1;
        return cast(float) (iVal - 8192) / 8192.0f;
    }

    alias pitchWheel = pitchBend;

    /// Amount of pressure
    int polyAftertouch() const
    {
        assert(isPolyAftertouch());
        return _data2;
    }

    /// Program number
    int program() const
    {
        assert(isProgramChange());
        return _data1;
    }

private:
    int _offset = 0;

    ubyte _statusByte = 0;

    ubyte _data1 = 0;

    ubyte _data2 = 0;
}


enum MidiStatus : ubyte
{
    none = 0,
    noteOff = 8,
    noteOn = 9,
    polyAftertouch = 10,
    controlChange = 11,
    programChange = 12,
    channelAftertouch = 13,
    pitchBend = 14,
    pitchWheel = pitchBend
};

enum MidiControlChange : ubyte
{
    modWheel = 1,
    breathController = 2,
    undefined003 = 3,
    footController = 4,
    portamentoTime = 5,
    channelVolume = 7,
    balance = 8,
    undefined009 = 9,
    pan = 10,
    expressionController = 11,
    effectControl1 = 12,
    effectControl2 = 13,
    generalPurposeController1 = 16,
    generalPurposeController2 = 17,
    generalPurposeController3 = 18,
    generalPurposeController4 = 19,
    sustainOnOff = 64,
    portamentoOnOff = 65,
    sustenutoOnOff = 66,
    softPedalOnOff = 67,
    legatoOnOff = 68,
    hold2OnOff = 69,
    soundVariation = 70,
    resonance = 71,
    releaseTime = 72,
    attackTime = 73,
    cutoffFrequency = 74,
    decayTime = 75,
    vibratoRate = 76,
    vibratoDepth = 77,
    vibratoDelay = 78,
    soundControllerUndefined = 79,
    tremoloDepth = 92,
    chorusDepth = 93,
    phaserDepth = 95,
    allSoundsOff = 120,
    allNotesOff = 123
}

nothrow @nogc:

MidiMessage makeMidiMessage(int offset, int channel, MidiStatus statusType, int data1, int data2)
{
    assert(channel >= 0 && channel <= 15);
    assert(statusType >= 0 && statusType <= 15);
    assert(data1 >= 0 && data2 <= 255);
    assert(data1 >= 0 && data2 <= 255);
    MidiMessage msg;
    msg._offset = offset;
    msg._statusByte = cast(ubyte)( channel | (statusType << 4) );
    msg._data1 = cast(ubyte)data1;
    msg._data2 = cast(ubyte)data2;
    return msg;
}

MidiMessage makeMidiMessageNoteOn(int offset, int channel, int noteNumber, int velocity)
{
    return makeMidiMessage(offset, channel, MidiStatus.noteOn, noteNumber, velocity);
}

MidiMessage makeMidiMessageNoteOff(int offset, int channel, int noteNumber)
{
    return makeMidiMessage(offset, channel, MidiStatus.noteOff, noteNumber, 0);
}

MidiMessage makeMidiMessagePitchWheel(int offset, int channel, float value)
{
    int ivalue = 8192 + cast(int)(value * 8192.0);
    if (ivalue < 0)
        ivalue = 0;
    if (ivalue > 16383)
        ivalue = 16383;
    return makeMidiMessage(offset, channel, MidiStatus.pitchWheel, ivalue & 0x7F, ivalue >> 7);
}

MidiMessage makeMidiMessageControlChange(int offset, int channel, MidiControlChange index, float value)
{
    // MAYDO: mapping is a bit strange here, not sure it can make +127 except exactly for 1.0f
    return makeMidiMessage(offset, channel, MidiStatus.controlChange, index, cast(int)(value * 127.0f) );
}


MidiQueue makeMidiQueue()
{
    return MidiQueue(42);
}

/// Queue for MIDI messages
/// TODO: use a priority queue
struct MidiQueue
{
nothrow:
@nogc:

    enum QueueCapacity = 511;

    private this(int dummy)
    {
        _outMessages = makeVec!MidiMessage(QueueCapacity);
    }

    @disable this(this);

    ~this()
    {
    }

    void initialize()
    {
        // Clears all pending MIDI messages
        _framesElapsed = 0;
        _numElements = 0;
        _insertOrder = 0;
    }

    /// Enqueue a message in the priority queue.
    void enqueue(MidiMessage message)
    {
        // Tweak message to mark it with current stamp
        // This allows to have an absolute offset for MIDI messages.
        assert(message._offset >= 0);
        message._offset += _framesElapsed;
        insertElement(message);
    }

    /// Gets all the MIDI messages for the next `frames` samples.
    /// It is guaranteed to be in order relative to time.
    /// These messages are valid until the next call to `getNextMidiMessages`.
    const(MidiMessage)[] getNextMidiMessages(int frames)
    {
        _outMessages.clearContents();

        int framesLimit = _framesElapsed;

        if (!empty())
        {
            MidiMessage m = minElement();

            while(m._offset < (_framesElapsed + frames))
            {
                // Subtract the timestamp again
                m._offset -= _framesElapsed;
                assert(m._offset >= 0);
                assert(m._offset < frames);
                _outMessages.pushBack(m);
                popMinElement();

                if (empty())
                    break;

                m = minElement();
            }
        }
        _framesElapsed += frames;
        return _outMessages[];
    }

private:

    // Frames elapsed since the beginning
    int _framesElapsed = 0;

    // Scratch buffer to return slices of messages on demand (messages are copied there).
    Vec!MidiMessage _outMessages;

    //
    // Min heap implementation below.
    //
    int _numElements = 0;

    /// Rolling counter used to disambiguate from messages pushed with the same timestamp.
    uint _insertOrder = 0;

    // Useful slots are in 1..QueueCapacity+1
    // means it can contain QueueCapacity items at most
    MidiMessageWithOrder[QueueCapacity+1] _heap;

    static struct MidiMessageWithOrder
    {
        MidiMessage message;
        uint order;
    }

    void insertElement(MidiMessage message)
    {
        // Insert the element at the next available bottom level slot
        int slot = _numElements + 1;

        _numElements++;

        if (slot >= _heap.length)
        {
            // TODO: limitation here, we can't accept more than QueueCapacity MIDI messages in the queue
            debug
            {
                // MIDI messages heap is on full capacity.
                // That can happen because you have forgotten to call `getNextMidiMessages`
                // with the necessary number of frames.
                assert(false);
            }
            else
            {
                return; // dropping excessive message
            }
        }

        _heap[slot] = MidiMessageWithOrder(message, _insertOrder++);

        // Bubble up
        while (slot > 1 && compareLargerThan(_heap[parentOf(slot)], _heap[slot]))
        {
            // swap with parent if should be popped later
            swap(_heap[slot], _heap[parentOf(slot)]);
            slot = parentOf(slot);
        }
    }

    bool empty()
    {
        assert(_numElements >= 0);
        return _numElements == 0;
    }

    MidiMessage minElement()
    {
        assert(!empty);
        return _heap[1].message;
    }

    void popMinElement()
    {
        assert(!empty);

        // Put the last element into root
        _heap[1] = _heap[_numElements];

        _numElements = _numElements-1;

        int slot = 1;

        if (slot >= _heap.length)
        {
            debug assert(false); // dropping excessive message
        }

        while (1)
        {
            // Looking for the minimum of self and children

            int left = leftChildOf(slot);
            int right = rightChildOf(slot);
            int best = slot;

            if ((left <= _numElements) && compareLargerThan(_heap[best], _heap[left]))
            {
                best = left;
            }
            if (right <= _numElements && compareLargerThan(_heap[best], _heap[right]))
            {
                best = right;
            }

            if (best == slot) // no swap, final position
            {
                // both children (if any) are larger, everything good
                break;
            }
            else
            {
                // swap with smallest of children
                swap(_heap[slot], _heap[best]);

                // continue to bubble down
                slot = best;
            }
        }
    }

    static int parentOf(int index)
    {
        return index >> 1;
    }

    static int leftChildOf(int index)
    {
        return 2*index;
    }

    static int rightChildOf(int index)
    {
        return 2*index+1;
    }

    // Larger means "should be popped later"
    // Priorities can't ever be equal.
    private static bool compareLargerThan(MidiMessageWithOrder a, MidiMessageWithOrder b)
    {
        if (a.message._offset != b.message._offset) 
        {
            return a.message._offset > b.message._offset;
        }
        if (a.order != b.order)
        {
            int diff = cast(int)(a.order - b.order);
            return (diff > 0);
        }
        else
        {
            // Impossible, unless 2^32 messages have been pushed with the same timestamp
            assert(false);
        }
    }
}

unittest
{
    MidiQueue queue = makeMidiQueue();
    foreach (k; 0..2)
    {
        // Enqueue QueueCapacity messages with decreasing timestamps
        foreach(i; 0..MidiQueue.QueueCapacity)
        {
            queue.enqueue( makeMidiMessageNoteOn(MidiQueue.QueueCapacity-1-i, 0, 60, 100) );
            assert(queue._numElements == i+1);
        }

        const(MidiMessage)[] messages = queue.getNextMidiMessages(1024);

        foreach(size_t i, m; messages)
        {
            // each should be in order
            assert(m.offset == cast(int)i);

            assert(m.isNoteOn);
        }
    }
}

// Issue #575: MidiQueue should NOT reorder messages that come with same timestamp.
unittest
{
    MidiQueue queue = makeMidiQueue();
    int note = 102;
    int vel = 64;
    int chan = 1;
    int offset = 0;

    queue.enqueue( makeMidiMessageNoteOn(offset, chan, note, vel) );
    queue.enqueue( makeMidiMessageNoteOn(offset, chan, note, vel) );
    queue.enqueue( makeMidiMessageNoteOff(offset, chan, note) );
    queue.enqueue( makeMidiMessageNoteOff(offset, chan, note) );

    const(MidiMessage)[] messages = queue.getNextMidiMessages(1024);
    assert(messages.length == 4);
    assert(messages[0].isNoteOn());
    assert(messages[1].isNoteOn());
    assert(messages[2].isNoteOff());
    assert(messages[3].isNoteOff());
}