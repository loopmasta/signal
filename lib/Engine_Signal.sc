// Engine_Signal: a simple lab signal generator for norns.
// sine / triangle / square / saw / white noise, optional second tone,
// log frequency sweep (up, down, up-down) with a poll for its position,
// one-shot tone burst, L / R / both output. The output signal itself, one cycle of the
// first tone in 62 samples, goes to the script as OSC /signal_scope 15 times a second.

Engine_Signal : CroneEngine {
	var synth, posBus, scopeBuf, scopeAddr, scopeTask;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		SynthDef(\signal, {
			arg out = 0,
				wave = 0, hz = 1000, hz2 = 2000, tone2 = 0,
				amp = 0.03, on = 0, chan = 0,
				sweep = 0, lo = 300, hi = 3000, swtime = 5,
				bdur = 0.5, t_burst = 0, t_sweepreset = 0, posbus = 0, scopebuf = 0;

			var gen, f, f2, cyc, phase, sig, gate, l, r, lof, hif;

			lof = lo.max(1);
			hif = hi.max(lof + 1);

			// where the sweep is in its cycle, 0..1 (a trigger sets it back to 0; published for the screen), and the
			// position on the frequency scale: sweep 0 off, 1 up, 2 down, 3 up and down
			cyc = Phasor.kr(t_sweepreset, ControlDur.ir / swtime.max(0.1), 0, 1);
			Out.kr(posbus, cyc);
			phase = Select.kr(sweep.clip(0, 3), [
				0,
				cyc,
				1 - cyc,
				1 - (2 * cyc - 1).abs
			]);

			f = Select.kr(sweep.clip(0, 3) > 0, [
				Lag.kr(hz, 0.02),
				lof * (hif / lof).pow(phase)
			]).clip(1, 20000);
			f2 = Lag.kr(hz2, 0.02).clip(1, 20000);

			gen = { arg freq;
				Select.ar(wave.clip(0, 4), [
					SinOsc.ar(freq),
					LFTri.ar(freq),
					Pulse.ar(freq, 0.5),
					Saw.ar(freq),
					WhiteNoise.ar
				])
			};

			sig = gen.(f);
			// two-tone: each tone at half level so the sum peaks at `amp`
			sig = Select.ar(tone2.clip(0, 1), [sig, (sig + gen.(f2)) * 0.5]);

			// output switch or a one-shot burst of `bdur` seconds
			gate = Lag.kr(max(on, Trig1.kr(t_burst, bdur)), 0.003);

			sig = sig * gate * Lag.kr(amp, 0.02);

			// the output signal over one cycle of the first tone, 62 samples (the width of
			// the view on the screen): a phase that runs once per cycle picks the buffer
			// place, so the picture stands still, and noise just shows its latest samples
			BufWr.ar(sig, scopebuf, Phasor.ar(0, f * SampleDur.ir * 62, 0, 62));

			// chan: 0 both, 1 left, 2 right. (`!=` is not a signal operation in
			// SuperCollider: it gives a plain boolean, so only < and > are used)
			l = (chan < 1.5);
			r = (chan < 0.5) + (chan > 1.5);
			Out.ar(out, [sig * l, sig * r]);
		}).add;

		posBus = Bus.control(context.server, 1);
		scopeBuf = Buffer.alloc(context.server, 62, 1);
		context.server.sync;

		synth = Synth.new(\signal, [
			\out, context.out_b.index,
			\posbus, posBus.index,
			\scopebuf, scopeBuf.bufnum
		], context.xg);

		// the samples to the script (norns' data polls are broken: they put every byte at
		// index 1), as an OSC message to the script's port
		scopeAddr = NetAddr("127.0.0.1", 10111);
		scopeTask = Routine({
			loop {
				scopeBuf.getn(0, 62, { arg data; scopeAddr.sendMsg('/signal_scope', *data) });
				(1 / 15).wait;
			}
		}).play(SystemClock);

		this.addPoll(\sweep_pos, { posBus.getSynchronous });

		this.addCommand(\wave,    "i", { arg msg; synth.set(\wave,   msg[1]) });
		this.addCommand(\hz,      "f", { arg msg; synth.set(\hz,     msg[1]) });
		this.addCommand(\hz2,     "f", { arg msg; synth.set(\hz2,    msg[1]) });
		this.addCommand(\tone2,   "i", { arg msg; synth.set(\tone2,  msg[1]) });
		this.addCommand(\amp,     "f", { arg msg; synth.set(\amp,    msg[1]) });
		this.addCommand(\on,      "i", { arg msg; synth.set(\on,     msg[1]) });
		this.addCommand(\chan,    "i", { arg msg; synth.set(\chan,   msg[1]) });
		this.addCommand(\sweep,   "i", { arg msg; synth.set(\sweep,  msg[1]) });
		this.addCommand(\lo,      "f", { arg msg; synth.set(\lo,     msg[1]) });
		this.addCommand(\hi,      "f", { arg msg; synth.set(\hi,     msg[1]) });
		this.addCommand(\swtime,  "f", { arg msg; synth.set(\swtime, msg[1]) });
		this.addCommand(\sweepreset, "", { arg msg; synth.set(\t_sweepreset, 1) });
		this.addCommand(\burst,   "f", { arg msg;
			synth.set(\bdur, msg[1]);
			synth.set(\t_burst, 1);
		});
	}

	free {
		scopeTask.stop;
		synth.free;
		posBus.free;
		scopeBuf.free;
	}
}
