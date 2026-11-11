extends RefCounted
## Synthesises the click track, so the beat timing is exact by construction
## and the project needs no audio files.


## One decaying sine blip, padded with silence to `total_samples`.
static func _tone(freq: float, duration: float, volume: float, mix_rate: int, total_samples: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(total_samples * 2)
	var count := mini(int(duration * mix_rate), total_samples)
	for i in count:
		var t := float(i) / mix_rate
		var sample := sin(TAU * freq * t) * exp(-t * 70.0) * volume
		bytes.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32767.0))
	return bytes


static func _wav(data: PackedByteArray, mix_rate: int) -> AudioStreamWAV:
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = mix_rate
	stream.stereo = false
	stream.data = data
	return stream


## A short one-shot sound for hit feedback.
static func blip(freq: float, duration: float, volume: float, mix_rate: int) -> AudioStreamWAV:
	return _wav(_tone(freq, duration, volume, mix_rate, int(duration * mix_rate)), mix_rate)


## Returns {"stream": AudioStreamWAV, "beat_len": seconds per beat}.
## Beats are a whole number of samples, so `beat_len` matches the audio exactly.
static func build_track(bpm: float, beats: int, mix_rate: int) -> Dictionary:
	var samples_per_beat := int(round(mix_rate * 60.0 / bpm))
	var accent := _tone(1760.0, 0.05, 0.8, mix_rate, samples_per_beat)
	var normal := _tone(1175.0, 0.04, 0.5, mix_rate, samples_per_beat)
	var bar := PackedByteArray()
	bar.append_array(accent)
	for i in 3:
		bar.append_array(normal)
	var data := PackedByteArray()
	for i in int(ceil(beats / 4.0)):
		data.append_array(bar)
	return {
		"stream": _wav(data, mix_rate),
		"beat_len": float(samples_per_beat) / mix_rate,
	}
