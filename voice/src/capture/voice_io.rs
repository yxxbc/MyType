//! macOS Voice Processing I/O：只采集麦克风，利用系统回声抑制和临时 ducking。

use std::ffi::c_void;
use std::mem::{size_of, MaybeUninit};
use std::ptr::{self, NonNull};

use anyhow::{anyhow, ensure, Result};
use coreaudio_sys::*;

use super::{CaptureInfo, Resampler, TARGET_RATE};

const MIC: u32 = 1;
const SPEAKER: u32 = 0;

struct Input {
    unit: AudioUnit,
    buffer: Vec<f32>,
    resampler: Resampler,
    sink: Box<dyn FnMut(Vec<i16>) + Send>,
}

pub(super) struct VoiceIo {
    unit: AudioUnit,
    input: Option<Box<Input>>,
    initialized: bool,
}

impl Drop for VoiceIo {
    fn drop(&mut self) {
        // 要等回调停了再释放传给 Core Audio 的回调上下文。
        unsafe {
            if self.initialized {
                AudioOutputUnitStop(self.unit);
                AudioUnitUninitialize(self.unit);
            }
            AudioComponentInstanceDispose(self.unit);
        }
    }
}

fn status(code: OSStatus, operation: &str) -> Result<()> {
    ensure!(code == 0, "{operation}：OSStatus {code}");
    Ok(())
}

fn set<T>(
    unit: AudioUnit,
    id: u32,
    scope: u32,
    element: u32,
    value: &T,
    label: &str,
) -> Result<()> {
    let code = unsafe {
        AudioUnitSetProperty(
            unit,
            id,
            scope,
            element,
            (value as *const T).cast(),
            size_of::<T>() as u32,
        )
    };
    status(code, label)
}

pub(super) fn start(sink: impl FnMut(Vec<i16>) + Send + 'static) -> Result<(VoiceIo, CaptureInfo)> {
    let desc = AudioComponentDescription {
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_VoiceProcessingIO,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0,
    };
    let component = unsafe { AudioComponentFindNext(ptr::null_mut(), &desc) };
    ensure!(!component.is_null(), "找不到 VoiceProcessingIO");
    let mut unit = ptr::null_mut();
    status(
        unsafe { AudioComponentInstanceNew(component, &mut unit) },
        "创建 VoiceProcessingIO",
    )?;
    ensure!(!unit.is_null(), "VoiceProcessingIO 句柄为空");
    let mut capture = VoiceIo {
        unit,
        input: None,
        initialized: false,
    };
    set(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input,
        MIC,
        &1u32,
        "启用语音麦克风",
    )?;
    set(
        unit,
        kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output,
        SPEAKER,
        &1u32,
        "启用回声参考",
    )?;

    // 该属性由 macOS 14 起支持。不支持时直接退出，保留原来的采集后端。
    let ducking = AUVoiceIOOtherAudioDuckingConfiguration {
        mEnableAdvancedDucking: 0,
        mDuckingLevel: kAUVoiceIOOtherAudioDuckingLevelMax,
    };
    set(
        unit,
        kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
        kAudioUnitScope_Global,
        SPEAKER,
        &ducking,
        "压低非语音音频",
    )?;

    let mut format = MaybeUninit::<AudioStreamBasicDescription>::uninit();
    let mut size = size_of::<AudioStreamBasicDescription>() as u32;
    status(
        unsafe {
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                MIC,
                format.as_mut_ptr().cast(),
                &mut size,
            )
        },
        "读取麦克风格式",
    )?;
    ensure!(
        size as usize == size_of::<AudioStreamBasicDescription>(),
        "麦克风格式长度错误"
    );
    let format = unsafe { format.assume_init() };
    let rate = format.mSampleRate;
    ensure!(
        rate.is_finite() && (8_000.0..=192_000.0).contains(&rate),
        "无效麦克风采样率"
    );
    let mono = AudioStreamBasicDescription {
        mSampleRate: rate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0,
    };
    set(
        unit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Output,
        MIC,
        &mono,
        "设置单声道麦克风",
    )?;

    capture.input = Some(Box::new(Input {
        unit,
        buffer: vec![0.0; 16_384],
        resampler: Resampler::new(rate.round() as u32, TARGET_RATE),
        sink: Box::new(sink),
    }));
    let context = capture
        .input
        .as_deref_mut()
        .ok_or_else(|| anyhow!("没有麦克风回调上下文"))?;
    let input = AURenderCallbackStruct {
        inputProc: Some(mic_input),
        inputProcRefCon: (context as *mut Input).cast(),
    };
    set(
        unit,
        kAudioOutputUnitProperty_SetInputCallback,
        kAudioUnitScope_Global,
        MIC,
        &input,
        "设置麦克风回调",
    )?;
    // 输出端保持开启供系统做回声处理，但不把麦克风播回扬声器。
    let silence = AURenderCallbackStruct {
        inputProc: Some(silent_output),
        inputProcRefCon: ptr::null_mut(),
    };
    set(
        unit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        SPEAKER,
        &silence,
        "设置静音回放",
    )?;

    status(unsafe { AudioUnitInitialize(unit) }, "初始化语音处理")?;
    capture.initialized = true;
    status(unsafe { AudioOutputUnitStart(unit) }, "启动语音处理")?;
    let info = CaptureInfo {
        device: "VoiceProcessingIO".into(),
        sample_rate: rate as u32,
        channels: 1,
        format: "F32".into(),
    };
    Ok((capture, info))
}

unsafe extern "C" fn mic_input(
    context: *mut c_void,
    flags: *mut AudioUnitRenderActionFlags,
    timestamp: *const AudioTimeStamp,
    _bus: u32,
    frames: u32,
    _output: *mut AudioBufferList,
) -> OSStatus {
    // Core Audio 对这个输入回调串行调用；VoiceIo 在停止、销毁 AudioUnit 后才释放它。
    let input = unsafe { &mut *context.cast::<Input>() };
    if frames as usize > input.buffer.len() || frames == 0 {
        return 0;
    }
    let mut data = AudioBufferList {
        mNumberBuffers: 1,
        mBuffers: [AudioBuffer {
            mNumberChannels: 1,
            mDataByteSize: frames * size_of::<f32>() as u32,
            mData: input.buffer.as_mut_ptr().cast(),
        }],
    };
    let result = unsafe { AudioUnitRender(input.unit, flags, timestamp, MIC, frames, &mut data) };
    if result != 0 {
        return result;
    }
    let count = (data.mBuffers[0].mDataByteSize as usize / size_of::<f32>()).min(frames as usize);
    let Some(samples) = NonNull::new(data.mBuffers[0].mData.cast::<f32>()) else {
        return 0;
    };
    let samples = unsafe { std::slice::from_raw_parts(samples.as_ptr(), count) };
    let mono = input.resampler.process(samples);
    (input.sink)(crate::audio::to_i16(&mono));
    0
}

unsafe extern "C" fn silent_output(
    _context: *mut c_void,
    flags: *mut AudioUnitRenderActionFlags,
    _timestamp: *const AudioTimeStamp,
    _bus: u32,
    _frames: u32,
    output: *mut AudioBufferList,
) -> OSStatus {
    unsafe {
        if let Some(flags) = flags.as_mut() {
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
        }
        if let Some(output) = output.as_mut() {
            let ptr = output.mBuffers.as_mut_ptr();
            for index in 0..output.mNumberBuffers as usize {
                let buffer = &mut *ptr.add(index);
                if !buffer.mData.is_null() {
                    buffer
                        .mData
                        .cast::<u8>()
                        .write_bytes(0, buffer.mDataByteSize as usize);
                }
            }
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_callback_cannot_play_back_microphone_audio() {
        let mut frames = [1.0f32; 8];
        let mut flags = 0;
        let mut buffers = AudioBufferList {
            mNumberBuffers: 1,
            mBuffers: [AudioBuffer {
                mNumberChannels: 1,
                mDataByteSize: size_of::<[f32; 8]>() as u32,
                mData: frames.as_mut_ptr().cast(),
            }],
        };
        let status = unsafe {
            silent_output(
                ptr::null_mut(),
                &mut flags,
                ptr::null(),
                SPEAKER,
                8,
                &mut buffers,
            )
        };
        assert_eq!(status, 0);
        assert_ne!(flags & kAudioUnitRenderAction_OutputIsSilence, 0);
        assert_eq!(frames, [0.0; 8]);
    }
}
