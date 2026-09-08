import React, { useEffect, useRef, useState } from 'react';
import { motion } from 'framer-motion';
import { useNavigate } from 'react-router-dom';
import { Header } from '../components/layout/Header';
import { Footer } from '../components/layout/Footer';
import { ContourField } from '../components/vfx/ContourField';
import { SectionWash } from '../components/vfx/OrbitField';
import { Scramble } from '../components/vfx/Scramble';
import heroDesktop from '../assets/hero-chat-desktop.webp';
import heroMobile from '../assets/hero-chat-mobile.webp';
import './Home.css';

/* ------------------------------------------------------------------ */
/* shared                                                              */
/* ------------------------------------------------------------------ */

const EASE = [0.22, 1, 0.36, 1] as const;

const Reveal = ({
    children,
    delay = 0,
    className,
}: {
    children: React.ReactNode;
    delay?: number;
    className?: string;
}) => (
    <motion.div
        className={className}
        initial={{ opacity: 0, y: 26 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true, margin: '-60px' }}
        transition={{ duration: 0.9, delay, ease: EASE }}
    >
        {children}
    </motion.div>
);

const SectionHead = ({ index, label }: { index: string; label: string }) => (
    <Reveal className="vl-section-head">
        <span className="vl-section-index">{index}</span>
        <span className="vl-section-rule" aria-hidden="true" />
        <Scramble className="vl-section-label" text={label} duration={700} />
    </Reveal>
);

/* ------------------------------------------------------------------ */
/* hero — static pre-blurred chat image + Ken Burns, short confident copy */
/* ------------------------------------------------------------------ */

const Hero = () => {
    const navigate = useNavigate();

    return (
        <section className="vl-storyline" id="top">
            <div className="vl-hero-ambient" aria-hidden="true">
                <div className="vl-hero-chat-drift">
                    <div
                        className="vl-hero-chat"
                        style={
                            {
                                '--hero-bg-desktop': `url(${heroDesktop})`,
                                '--hero-bg-mobile': `url(${heroMobile})`,
                            } as React.CSSProperties
                        }
                    />
                </div>
                <div className="vl-hero-veil" />
            </div>

            <div className="vl-hero-content">
                <Reveal>
                    <h1 className="vl-display vl-hero-title">
                        Sealed before it <em>leaves.</em>
                    </h1>
                </Reveal>
                <Reveal delay={0.08}>
                    <p className="vl-lede vl-hero-lede">
                        End-to-end encrypted messenger. Username only — a 256-bit key stays on your device.
                    </p>
                </Reveal>
                <Reveal delay={0.16} className="vl-cta-row">
                    <button className="vl-btn vl-btn--primary" onClick={() => navigate('/app')}>
                        Create your key
                        <span className="vl-btn-arrow" aria-hidden="true">→</span>
                    </button>
                    <button className="vl-btn vl-btn--ghost" onClick={() => navigate('/docs/agents')}>
                        Read the protocol
                    </button>
                </Reveal>
            </div>
        </section>
    );
};

/* ------------------------------------------------------------------ */
/* ticker                                                              */
/* ------------------------------------------------------------------ */

const TICKER_ITEMS = [
    'AES-256-GCM',
    'NO PHONE NUMBER',
    'DOMAIN FRONTING',
    'V2RAY · SHADOWSOCKS',
    'CLAUDE + CODEX IN-CHAT',
    'FORWARD SECRECY',
    'ZERO METADATA',
];

const Ticker = () => (
    <div className="vl-ticker" aria-hidden="true">
        <div className="vl-ticker-track">
            {[0, 1].map((half) => (
                <span className="vl-ticker-group" key={half}>
                    {TICKER_ITEMS.map((item) => (
                        <span className="vl-ticker-item" key={item}>
                            {item}
                            <i className="vl-ticker-dot" />
                        </span>
                    ))}
                </span>
            ))}
        </div>
    </div>
);

/* ------------------------------------------------------------------ */
/* 01 — cipher (hold to decrypt)                                       */
/* ------------------------------------------------------------------ */

const PLAINTEXT = 'Meet at the north gate at 21:00. Bring the drive — tell no one else.';
const HEXCHARS = '0123456789ABCDEF';

const sealedGlyph = (i: number, tick: number) => {
    const n = (i * 2654435761 + tick * 40503) >>> 0;
    return HEXCHARS[n % HEXCHARS.length];
};

const CipherDemo = () => {
    const rootRef = useRef<HTMLDivElement>(null);
    const [, force] = useState(0);
    const p = useRef(0);           // 0 = plaintext, 1 = sealed
    const target = useRef(0);
    const tick = useRef(0);
    const [holding, setHolding] = useState(false);
    const reduced = useRef(false);

    useEffect(() => {
        reduced.current = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        const el = rootRef.current;
        if (!el) return;

        let raf = 0;
        let last = 0;
        let lastTick = 0;
        let started = false;

        const loop = (now: number) => {
            const dt = last ? Math.min((now - last) / 1000, 0.05) : 0;
            last = now;
            let dirty = false;

            if (Math.abs(p.current - target.current) > 0.0005) {
                const dir = target.current > p.current ? 1 : -1;
                p.current = Math.max(0, Math.min(1, p.current + dir * dt * 1.7));
                dirty = true;
            }
            if (now - lastTick > 110) {
                lastTick = now;
                tick.current++;
                if (p.current > 0.01) dirty = true;
            }
            if (dirty) force((v) => v + 1);
            raf = requestAnimationFrame(loop);
        };

        const io = new IntersectionObserver(
            (entries) => {
                if (entries[0]?.isIntersecting && !started) {
                    started = true;
                    if (reduced.current) {
                        p.current = 1;
                        target.current = 1;
                        force((v) => v + 1);
                    } else {
                        target.current = 1;
                        raf = requestAnimationFrame(loop);
                    }
                    io.disconnect();
                }
            },
            { threshold: 0.5 }
        );
        io.observe(el);

        return () => {
            io.disconnect();
            cancelAnimationFrame(raf);
        };
    }, []);

    const hold = (down: boolean) => {
        setHolding(down);
        if (reduced.current) {
            p.current = down ? 0 : 1;
            force((v) => v + 1);
        }
        target.current = down ? 0 : 1;
    };

    const len = PLAINTEXT.length;
    const chars = PLAINTEXT.split('').map((c, i) => {
        if (c === ' ') return <span key={i}>&nbsp;</span>;
        const threshold = (i / len) * 0.82 + 0.06;
        const sealed = p.current > threshold;
        return (
            <span key={i} className={sealed ? 'vl-cipher-c is-sealed' : 'vl-cipher-c'}>
                {sealed ? sealedGlyph(i, tick.current) : c}
            </span>
        );
    });

    const sealedNow = p.current > 0.6;

    return (
        <div className="vl-cipher-card" ref={rootRef}>
            <div className="vl-cipher-head">
                <span>Message #4471</span>
                <span className={sealedNow ? 'vl-cipher-state is-sealed' : 'vl-cipher-state'}>
                    {sealedNow ? 'Sealed' : 'Plaintext'}
                </span>
            </div>
            <p className="vl-cipher-text">{chars}</p>
            <div className="vl-cipher-foot">
                <span className="vl-cipher-spec">
                    {sealedNow ? 'AES-256-GCM · IV 96-bit · tag verified' : 'Visible only while you hold'}
                </span>
                <button
                    className={holding ? 'vl-hold-btn is-holding' : 'vl-hold-btn'}
                    onPointerDown={() => hold(true)}
                    onPointerUp={() => hold(false)}
                    onPointerLeave={() => hold(false)}
                    onPointerCancel={() => hold(false)}
                    onKeyDown={(e) => {
                        if ((e.key === 'Enter' || e.key === ' ') && !e.repeat) hold(true);
                    }}
                    onKeyUp={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') hold(false);
                    }}
                    onContextMenu={(e) => e.preventDefault()}
                >
                    {holding ? 'Decrypting…' : 'Hold to decrypt'}
                </button>
            </div>
        </div>
    );
};

const CipherSection = () => (
    <section className="vl-section vl-section--cipher" id="cipher">
        <SectionWash tone="teal" />
        <SectionHead index="01" label="CIPHER" />
        <div className="vl-split vl-split--reverse">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        Sealed before it<br />
                        <em>leaves your hand.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Encryption isn&apos;t a feature toggle — it&apos;s the transport itself. Keys are
                        derived on-device from a secret only you hold; the network, the relays,
                        even Vibe itself only ever see noise.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <div className="vl-chips">
                        <span className="vl-chip">AES-256-GCM</span>
                        <span className="vl-chip">RSA-4096 identity</span>
                        <span className="vl-chip">Forward secrecy</span>
                    </div>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <CipherDemo />
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* 02 — passage (censorship route board)                               */
/* ------------------------------------------------------------------ */

interface PassagePhase {
    path: 'direct' | 'front' | 'tunnel';
    dur: number;
    cut?: number;
    log: string;
    ok: boolean;
}

const PHASES: PassagePhase[] = [
    { path: 'direct', dur: 1150, cut: 0.5, log: 'Direct route ··· RST injected at filter ✕', ok: false },
    { path: 'front', dur: 1750, log: 'Domain front · CDN edge ··· delivered ✓', ok: true },
    { path: 'tunnel', dur: 1750, log: 'V2Ray TLS tunnel ··· delivered ✓', ok: true },
];

const PassageBoard = () => {
    const rootRef = useRef<HTMLDivElement>(null);
    const packetRef = useRef<SVGCircleElement>(null);
    const burstRef = useRef<SVGGElement>(null);
    const pathRefs = {
        direct: useRef<SVGPathElement>(null),
        front: useRef<SVGPathElement>(null),
        tunnel: useRef<SVGPathElement>(null),
    };
    const [logs, setLogs] = useState<Array<{ text: string; ok: boolean; id: number }>>([]);

    useEffect(() => {
        const root = rootRef.current;
        if (!root) return;
        const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

        if (reduced) {
            setLogs(PHASES.map((ph, i) => ({ text: ph.log, ok: ph.ok, id: i })).reverse());
            return;
        }

        let raf = 0;
        let running = false;
        let inView = false;
        let phaseIdx = 0;
        let phaseStart = 0;
        let logged = false;
        let logId = 0;

        const PACKET_COLORS: Record<PassagePhase['path'], string> = {
            direct: '#f0716d',
            front: '#63e2d9',
            tunnel: '#9c8cff',
        };

        const loop = (now: number) => {
            if (!running) return;
            if (!phaseStart) phaseStart = now;
            const phase = PHASES[phaseIdx % PHASES.length];
            const el = pathRefs[phase.path].current;
            const packet = packetRef.current;
            const burst = burstRef.current;
            const elapsed = now - phaseStart;
            const HOLD = 1000;

            if (el && packet) {
                if (elapsed < phase.dur) {
                    const t = elapsed / phase.dur;
                    const eased = t * t * (3 - 2 * t);
                    const L = el.getTotalLength() * (phase.cut ?? 1);
                    const pt = el.getPointAtLength(eased * L);
                    packet.setAttribute('cx', String(pt.x));
                    packet.setAttribute('cy', String(pt.y));
                    packet.setAttribute('fill', PACKET_COLORS[phase.path]);
                    packet.setAttribute('opacity', '1');
                } else {
                    packet.setAttribute('opacity', '0');
                    if (!logged) {
                        logged = true;
                        const entry = { text: phase.log, ok: phase.ok, id: logId++ };
                        setLogs((prev) => [entry, ...prev].slice(0, 3));
                        if (!phase.ok && burst) {
                            burst.setAttribute('opacity', '1');
                            window.setTimeout(() => burst.setAttribute('opacity', '0'), 450);
                        }
                    }
                    if (elapsed > phase.dur + HOLD) {
                        phaseIdx++;
                        phaseStart = now;
                        logged = false;
                    }
                }
            }
            raf = requestAnimationFrame(loop);
        };

        const syncRunning = () => {
            const should = inView && !document.hidden;
            if (should && !running) {
                running = true;
                phaseStart = 0;
                raf = requestAnimationFrame(loop);
            } else if (!should && running) {
                running = false;
                cancelAnimationFrame(raf);
            }
        };

        const io = new IntersectionObserver((entries) => {
            inView = entries[0]?.isIntersecting ?? false;
            syncRunning();
        });
        io.observe(root);
        const onVisibility = () => syncRunning();
        document.addEventListener('visibilitychange', onVisibility);

        return () => {
            running = false;
            cancelAnimationFrame(raf);
            io.disconnect();
            document.removeEventListener('visibilitychange', onVisibility);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    return (
        <div className="vl-passage" ref={rootRef}>
            <div className="vl-stage vl-passage-stage">
                <svg viewBox="0 0 640 360" className="vl-passage-svg" aria-hidden="true">
                    {/* filter wall */}
                    <g className="vl-wall">
                        <line x1="320" y1="118" x2="320" y2="242" />
                        {Array.from({ length: 8 }, (_, i) => (
                            <line key={i} x1="314" y1={124 + i * 16} x2="326" y2={116 + i * 16} />
                        ))}
                        <text x="332" y="182" className="vl-svg-label vl-svg-label--wall">DPI filter</text>
                    </g>

                    {/* routes */}
                    <path ref={pathRefs.direct} className="vl-route vl-route--direct" d="M 60 180 L 580 180" />
                    <path ref={pathRefs.front} className="vl-route vl-route--front" d="M 60 180 C 190 60, 450 60, 580 180" />
                    <path ref={pathRefs.tunnel} className="vl-route vl-route--tunnel" d="M 60 180 C 190 300, 450 300, 580 180" />

                    {/* waypoints */}
                    <circle cx="320" cy="90" r="3" className="vl-waypoint vl-waypoint--front" />
                    <text x="320" y="74" className="vl-svg-label" textAnchor="middle">cdn · front</text>
                    <circle cx="320" cy="270" r="3" className="vl-waypoint vl-waypoint--tunnel" />
                    <text x="320" y="296" className="vl-svg-label" textAnchor="middle">v2ray · tls</text>

                    {/* endpoints */}
                    <circle cx="60" cy="180" r="5" className="vl-endpoint" />
                    <text x="60" y="212" className="vl-svg-label" textAnchor="middle">You</text>
                    <circle cx="580" cy="180" r="5" className="vl-endpoint" />
                    <text x="580" y="212" className="vl-svg-label" textAnchor="middle">Peer</text>

                    {/* burst on block */}
                    <g ref={burstRef} opacity="0" className="vl-burst">
                        <line x1="312" y1="172" x2="328" y2="188" />
                        <line x1="328" y1="172" x2="312" y2="188" />
                    </g>

                    <circle ref={packetRef} r="4" opacity="0" className="vl-packet" />
                </svg>
            </div>
            <div className="vl-passage-log" aria-live="polite">
                {logs.map((l) => (
                    <div key={l.id} className={l.ok ? 'vl-log-line is-ok' : 'vl-log-line is-fail'}>
                        {l.text}
                    </div>
                ))}
                {logs.length === 0 && <div className="vl-log-line">Awaiting traffic…</div>}
            </div>
        </div>
    );
};

const PassageSection = () => (
    <section className="vl-section vl-section--passage" id="passage">
        <SectionWash tone="teal" />
        <SectionHead index="02" label="PASSAGE" />
        <div className="vl-split">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        When the wall goes up,<br />
                        <em>the route goes around.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Deep-packet inspection kills the direct line — so Vibe never insists on one.
                        Traffic reshapes itself as ordinary CDN requests or slips through V2Ray-patterned
                        TLS tunnels until something gets through. Something always gets through.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <div className="vl-chips">
                        <span className="vl-chip">Domain fronting</span>
                        <span className="vl-chip">V2Ray</span>
                        <span className="vl-chip">Shadowsocks</span>
                        <span className="vl-chip">Snowflake</span>
                    </div>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <PassageBoard />
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* 03 — agents (auto-typing terminal)                                  */
/* ------------------------------------------------------------------ */

interface TermLine {
    kind: 'cmd' | 'sys' | 'tool' | 'ok';
    text: string;
}

const SCRIPT: TermLine[] = [
    { kind: 'cmd', text: 'you ▸ @claude the login screen crashes on iPhone — fix it' },
    { kind: 'sys', text: 'claude · connected to MacBook-Pro · repo vibe/ios' },
    { kind: 'tool', text: '⏺ Grep   "session restore" — 14 hits' },
    { kind: 'tool', text: '⏺ Read   ChatEngine.swift' },
    { kind: 'tool', text: '⏺ Edit   ChatEngine.swift  +12 −3' },
    { kind: 'tool', text: '⏺ Build  succeeded · 0 warnings' },
    { kind: 'ok', text: 'claude ▸ Fixed — race in session restore. Diff attached to this chat.' },
    { kind: 'cmd', text: 'you ▸ run it on my phone' },
    { kind: 'ok', text: 'claude ▸ Installed on iPhone 16 Pro Max ✓' },
];

const AgentTerminal = () => {
    const rootRef = useRef<HTMLDivElement>(null);
    const [cursor, setCursor] = useState<{ line: number; chars: number }>({ line: -1, chars: 0 });

    useEffect(() => {
        const root = rootRef.current;
        if (!root) return;

        if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            setCursor({ line: SCRIPT.length, chars: 0 });
            return;
        }

        const timers: number[] = [];
        let started = false;
        const schedule = (fn: () => void, ms: number) => {
            timers.push(window.setTimeout(fn, ms));
        };

        const run = () => {
            setCursor({ line: -1, chars: 0 });
            let acc = 500;
            SCRIPT.forEach((line, li) => {
                if (line.kind === 'cmd') {
                    for (let c = 1; c <= line.text.length; c++) {
                        schedule(() => setCursor({ line: li, chars: c }), acc);
                        acc += 22;
                    }
                    acc += 550;
                } else {
                    schedule(() => setCursor({ line: li, chars: line.text.length }), acc);
                    acc += line.kind === 'tool' ? 540 : 850;
                }
            });
            schedule(() => setCursor({ line: SCRIPT.length, chars: 0 }), acc);
            schedule(run, acc + 4500);
        };

        const io = new IntersectionObserver(
            (entries) => {
                if (entries[0]?.isIntersecting && !started) {
                    started = true;
                    run();
                    io.disconnect();
                }
            },
            { threshold: 0.35 }
        );
        io.observe(root);

        return () => {
            io.disconnect();
            timers.forEach((t) => window.clearTimeout(t));
        };
    }, []);

    return (
        <div className="vl-terminal" ref={rootRef}>
            <div className="vl-terminal-bar">
                <span className="vl-term-dots" aria-hidden="true"><i /><i /><i /></span>
                <span className="vl-term-title">vibe · agent bridge</span>
                <span className="vl-term-status">Live</span>
            </div>
            <div className="vl-terminal-body">
                {SCRIPT.map((line, li) => {
                    if (li > cursor.line) return null;
                    const partial = li === cursor.line;
                    const text = partial ? line.text.slice(0, cursor.chars) : line.text;
                    return (
                        <div key={li} className={`vl-term-line vl-term-line--${line.kind}`}>
                            {text}
                            {partial && line.kind === 'cmd' && <span className="vl-term-caret" />}
                        </div>
                    );
                })}
                {cursor.line >= SCRIPT.length && (
                    <div className="vl-term-line vl-term-line--cmd">
                        you ▸ <span className="vl-term-caret" />
                    </div>
                )}
            </div>
        </div>
    );
};

const AgentsSection = () => (
    <section className="vl-section vl-section--agents" id="agents">
        <SectionWash tone="violet" />
        <SectionHead index="03" label="AGENTS" />
        <div className="vl-split vl-split--reverse">
            <div className="vl-split-copy">
                <Reveal>
                    <h2 className="vl-h2">
                        Your repo,<br />
                        <em>in your pocket.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.1}>
                    <p className="vl-prose">
                        Claude and Codex are first-class citizens of your chats. Agents run on your
                        own machine, stream every tool call to your phone end-to-end encrypted, and
                        wait for your approval before anything ships. DM one — or put both in a group
                        and let them race.
                    </p>
                </Reveal>
                <Reveal delay={0.18}>
                    <a className="vl-textlink vl-textlink--violet" href="/docs/agents">
                        Agent bridge documentation <span aria-hidden="true">↗</span>
                    </a>
                </Reveal>
            </div>
            <Reveal delay={0.12} className="vl-split-stage">
                <AgentTerminal />
            </Reveal>
        </div>
    </section>
);

/* ------------------------------------------------------------------ */
/* join + footer                                                       */
/* ------------------------------------------------------------------ */

const JoinSection = () => {
    const navigate = useNavigate();
    return (
        <section className="vl-join" id="join">
            <SectionWash tone="blend" />
            <div className="vl-join-inner">
                <Reveal>
                    <p className="vl-kicker vl-kicker--blend">No phone number · No email · One key</p>
                </Reveal>
                <Reveal delay={0.08}>
                    <h2 className="vl-display vl-display--join">
                        Own the key.<br /><em>Own the conversation.</em>
                    </h2>
                </Reveal>
                <Reveal delay={0.16}>
                    <div className="vl-cta-row vl-cta-row--center">
                        <button className="vl-btn vl-btn--primary" onClick={() => navigate('/app')}>
                            Generate my key
                            <span className="vl-btn-arrow" aria-hidden="true">→</span>
                        </button>
                        <button className="vl-btn vl-btn--ghost" onClick={() => navigate('/app')}>
                            I already have one
                        </button>
                    </div>
                </Reveal>
                <Reveal delay={0.24}>
                    <p className="vl-join-fine">
                        A 256-bit secret, generated on your device. We never see it — and never can.
                    </p>
                </Reveal>
            </div>
        </section>
    );
};

/* ------------------------------------------------------------------ */
/* page                                                                */
/* ------------------------------------------------------------------ */

const Home = () => (
    <div className="vl-root">
        <ContourField className="vl-shader" intensity={0.72} />
        <Header />
        <main className="vl-main">
            <Hero />
            <Ticker />
            <CipherSection />
            <PassageSection />
            <AgentsSection />
            <JoinSection />
        </main>
        <Footer />
    </div>
);

export default Home;
