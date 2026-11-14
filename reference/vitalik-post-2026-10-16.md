# Vitalik's post, 16 October 2026, in his words

Source: <https://x.com/VitalikButerin/status/2111046730959433793>, posted
10:48Z on 16 October 2026. Pasted in full by Sean on 14 November 2026. This
is the description Cloak is measured against (S01 in docs/spec-v0.4.md);
[baseline.md](baseline.md) is our reading of it. The post showed a recording
of a research task after "looks like."; that recording is not kept here.

> Wrapped zkAPI + Tor + extra cover traffic + local LLM prompt rewriting in
> an open-AI compatible daemon, and made a "paranoid mode" wrapper for my
> agent harness (pi):
>
> Each conversation gets assigned a separate Tor circuit, your requests are
> masked with random cover traffic, zkAPI ensures you don't leak your
> identity through payments, and all prompts are locally rewritten
> (bring-your-own-local-model; I'm using qwen3.8-flash-next)
>
> https://github.com/vbuterin/zkapi/tree/feat/client-concession-local
>
> My agent harness is wrapped with a bwrap sandbox (also experimenting with
> MicroVM) and wrapped again with torsocks, so everything it does goes
> through Tor.
>
> Here's what me asking it to do a simple research task looks like.
>
> It's getting quite usable! Though you definitely still pay quite a bit in
> increased latency, especially when starting a new conversation.
>
> Also, Tor is far from optimal here for privacy; the cover traffic
> mechanism is okay against passive adversaries but much weaker if the LLM
> provider is colluding with the guard and actively manipulating timing.
> This kind of task really requires a more specialized mixnet, probably take
> the tradeoff of a higher bandwidth multiplier and built-in constant cover
> traffic.
>
> Also also, much cheaper zkAPI deposit and withdraw gas costs are coming to
> mainnet soon.

Sean gave this link beside it: <https://github.com/ethereum/zkapi>.
