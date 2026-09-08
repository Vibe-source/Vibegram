import React, { useEffect, useRef, useState, useCallback } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Header } from '../layout/Header';
import type { AgentDocsTab } from '../../pages/agentDocsShared';
import '../../pages/AgentDocs.css';

export interface DocsSectionLink {
    id: string;
    label: string;
    children?: { id: string; label: string }[];
}

interface DocsShellProps {
    eyebrow: string;
    title: string;
    intro: string;
    tabs: AgentDocsTab[];
    sections: DocsSectionLink[];
    sidebarLabel?: string;
    children: React.ReactNode;
}

function CodeBlock({ lang, code }: { lang: string; code: string }) {
    const [copied, setCopied] = useState(false);

    const handleCopy = () => {
        navigator.clipboard.writeText(code).then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        });
    };

    return (
        <div className="docs-code-block">
            <div className="docs-code-header">
                <span className="docs-code-lang">{lang}</span>
                <button
                    type="button"
                    className={`docs-code-copy ${copied ? 'copied' : ''}`}
                    onClick={handleCopy}
                >
                    {copied ? '✓ Copied' : 'Copy'}
                </button>
            </div>
            <pre><code>{code}</code></pre>
        </div>
    );
}

export { CodeBlock };

export default function DocsShell({
    eyebrow,
    title,
    intro,
    tabs,
    sections,
    sidebarLabel,
    children,
}: DocsShellProps) {
    const navigate = useNavigate();
    const location = useLocation();
    const [activeSection, setActiveSection] = useState<string>(sections[0]?.id ?? '');
    const mainRef = useRef<HTMLElement>(null);
    const observersRef = useRef<IntersectionObserver[]>([]);

    // scroll to hash on load / navigation
    useEffect(() => {
        const id = location.hash.replace(/^#/, '');
        if (!id) return;
        const node = document.getElementById(id);
        if (!node) return;
        requestAnimationFrame(() => node.scrollIntoView({ behavior: 'smooth', block: 'start' }));
        setActiveSection(id);
    }, [location.hash]);

    // intersection observers to highlight active TOC item
    useEffect(() => {
        observersRef.current.forEach(o => o.disconnect());
        observersRef.current = [];

        const allIds = sections.flatMap(s => [s.id, ...(s.children?.map(c => c.id) ?? [])]);

        allIds.forEach(id => {
            const el = document.getElementById(id);
            if (!el) return;
            const observer = new IntersectionObserver(
                ([entry]) => {
                    if (entry.isIntersecting) setActiveSection(id);
                },
                { rootMargin: '-20% 0px -70% 0px', threshold: 0 },
            );
            observer.observe(el);
            observersRef.current.push(observer);
        });

        return () => observersRef.current.forEach(o => o.disconnect());
    }, [sections]);

    const scrollTo = useCallback((id: string) => {
        const node = document.getElementById(id);
        if (!node) return;
        node.scrollIntoView({ behavior: 'smooth', block: 'start' });
        window.history.replaceState(null, '', `${location.pathname}#${id}`);
        setActiveSection(id);
    }, [location.pathname]);

    // Wire up copy buttons inside children (the lazy way — let CodeBlock handle it)
    useEffect(() => {
        const buttons = document.querySelectorAll<HTMLButtonElement>('.docs-code-tab-copy');
        buttons.forEach(btn => {
            btn.onclick = () => {
                const panel = btn.closest('.docs-code-tab-panel');
                const code = panel?.querySelector('code')?.textContent ?? '';
                navigator.clipboard.writeText(code).then(() => {
                    btn.textContent = '✓ Copied';
                    btn.classList.add('copied');
                    setTimeout(() => {
                        btn.textContent = 'Copy';
                        btn.classList.remove('copied');
                    }, 2000);
                });
            };
        });
    });

    return (
        <div className="docs-page-clean">
            <Header />

            <div className="docs-shell">
                {/* ── Left Sidebar ─────────────────── */}
                <aside className="docs-sidebar">
                    <div className="docs-sidebar-group">
                        <div className="docs-sidebar-label">{sidebarLabel ?? 'Agents'}</div>
                        <div className="docs-sidebar-nav">
                            {tabs.map(tab => (
                                <button
                                    key={tab.path}
                                    type="button"
                                    className={`docs-sidebar-tab ${location.pathname === tab.path ? 'active' : ''}`}
                                    onClick={() => navigate(tab.path)}
                                >
                                    {tab.label}
                                </button>
                            ))}
                        </div>
                    </div>
                </aside>

                {/* ── Main ─────────────────────────── */}
                <main className="docs-main" ref={mainRef}>
                    <div className="docs-main-container">
                        <header className="docs-header">
                            <span className="docs-eyebrow">{eyebrow}</span>
                            <h1 className="docs-shell-title">{title}</h1>
                            <p className="docs-shell-intro">{intro}</p>
                        </header>

                        <div className="docs-content">
                            {children}
                        </div>
                    </div>
                </main>

                {/* ── Right TOC ────────────────────── */}
                <nav className="docs-toc" aria-label="Table of contents">
                    <span className="docs-toc-label">On this page</span>
                    <ul className="docs-toc-list">
                        {sections.map(section => (
                            <li key={section.id} className="docs-toc-item">
                                <a
                                    className={`docs-toc-link ${activeSection === section.id ? 'active' : ''}`}
                                    href={`#${section.id}`}
                                    onClick={e => { e.preventDefault(); scrollTo(section.id); }}
                                >
                                    {section.label}
                                </a>
                                {section.children?.map(child => (
                                    <a
                                        key={child.id}
                                        className={`docs-toc-link ${activeSection === child.id ? 'active' : ''}`}
                                        href={`#${child.id}`}
                                        style={{ paddingLeft: 20, fontSize: 12 }}
                                        onClick={e => { e.preventDefault(); scrollTo(child.id); }}
                                    >
                                        {child.label}
                                    </a>
                                ))}
                            </li>
                        ))}
                    </ul>
                </nav>
            </div>
        </div>
    );
}
