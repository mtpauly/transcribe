import json
import sounddevice as sd
import soundfile as sf
import sys
import queue
import subprocess
from pynput import keyboard
from enum import Enum
import threading
import requests
from dotenv import load_dotenv
import base64
import os

filename = "./recordings/out_full.wav"

load_dotenv()
api_key = os.environ["OPENROUTER_API_KEY"]

class ListenerState(Enum):
    IDLE = 1
    LISTENING = 2
    TRANSCRIBING = 3

state = ListenerState.IDLE

data_queue = queue.Queue()

# Called while recording when the 
# TODO: is this necessary? maybe it buffers the data internally?
def input_stream_callback(indata, frames, time, status):
    if status:
        print(status, file=sys.stderr)
    data_queue.put(indata.copy())


# Called when the global hotkey is pressed
def on_activate():
    global state, data_queue

    if state == ListenerState.IDLE:
        print("Starting recording")
        state = ListenerState.LISTENING
        data_queue = queue.Queue()
        input_stream.start()
    elif state == ListenerState.LISTENING:
        print("Stopping recording and starting transcription")
        state = ListenerState.TRANSCRIBING
        t = threading.Thread(target=transcribe)
        t.start()
    elif state == ListenerState.TRANSCRIBING:
        print("Already transcribing, ignoring input")
        pass


# Transcribe and paste the currently-active listening session
def transcribe():
    input_stream.stop()

    # Write sound data
    with sf.SoundFile(filename, mode='w', samplerate=sample_rate, channels=1) as file:
        while not data_queue.empty():
            file.write(data_queue.get())

    # Transcribe text
    with open(filename, "rb") as f:
        base64_audio = base64.b64encode(f.read()).decode("utf-8")

    response = requests.post(
        url="https://openrouter.ai/api/v1/audio/transcriptions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            # "HTTP-Referer": "<YOUR_SITE_URL>", # Optional. Site URL for rankings on openrouter.ai.
            # "X-OpenRouter-Title": "<YOUR_SITE_NAME>", # Optional. Site title for rankings on openrouter.ai.
            },
        data=json.dumps({
            # https://openrouter.ai/docs/guides/overview/multimodal/stt
            "model": "microsoft/mai-transcribe-2",
            "input_audio": {
                "data": base64_audio,
                "format": filename.split(".")[-1]
            },

            # Omit "language" to auto-detect (with code switching), or pin it: "language": "en"
            # Segment and word timestamps
            # "response_format": "verbose_json",
            # "timestamp_granularities": ["word"],

            # Azure passthrough options, forwarded to the MAI-Transcribe definition
            # https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe?pivots=programming-language-rest#use-a-mai-transcribe-model
            "provider": {
                "options": {
                    "azure": {
                        # Speaker diarization: adds "speaker" to each segment and word
                        # "diarization": {"enabled": True},

                        # Keyword biasing for domain terms and proper nouns
                        # "phraseList": {"phrases": ["OpenRouter", "MAI-Transcribe"]},

                        # "clean" drops fillers and false starts; "verbatim" (default) keeps them
                        # "enhancedMode": {"modelOptions": {"transcribeStyle": "clean"}},
                        }
                    }
                }
            })
        )
    response.raise_for_status()
    transcribed_text = response.json()["text"]
    print(f"Transcribed text: {transcribed_text}")

    # Paste
    paste(transcribed_text)

    # Reset state
    global state
    state = ListenerState.IDLE


# Trigger a paste action with the given text
def paste(text: str):
    script = """
    on run argv
        set oldText to the clipboard as text
        set newText to item 1 of argv
        set the clipboard to newText

        tell application "System Events"
            keystroke "v" using command down
        end tell

        # TODO: why is this needed?
        delay 0.1
        if (the clipboard as text) is newText then
            set the clipboard to oldText
        end if
    end run
    """
    subprocess.run(["osascript", "-e", script, text], check=True)


if __name__ == '__main__':
    # Setup input stream
    default_mic = sd.query_devices(kind="input")
    sample_rate = int(default_mic["default_samplerate"])
    print(f'using default mic ({default_mic["name"]}) with sample rate {sample_rate}')

    input_stream = sd.InputStream(
        samplerate=sample_rate,
        device=default_mic["index"],
        channels=1,
        callback=input_stream_callback,
    )

    # Start key listener
    try:
        with keyboard.GlobalHotKeys(
            {"<alt>+<space>": on_activate},
        ) as h:
            h.join()
    except KeyboardInterrupt:
        print('exiting..')

    input_stream.close()
