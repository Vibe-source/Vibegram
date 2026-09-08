import React from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import './Header.css';

const BrandGlyph = () => (
    <svg className="vl-brand-glyph" width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="7.4" fill="none" stroke="currentColor" strokeWidth="1.1" opacity="0.55" />
        <circle cx="9" cy="9" r="2.4" fill="currentColor" />
        <circle cx="14.6" cy="4.2" r="1.5" fill="currentColor" opacity="0.85" />
    </svg>
);

export const Header = () => {
    const navigate = useNavigate();
    const location = useLocation();
    const [mobileMenuOpen, setMobileMenuOpen] = React.useState(false);
    const [scrolled, setScrolled] = React.useState(false);
    const isDocsPage = location.pathname.startsWith('/docs');

    React.useEffect(() => {
        const onScroll = () => setScrolled(window.scrollY > 24);
        onScroll();
        window.addEventListener('scroll', onScroll, { passive: true });
        return () => window.removeEventListener('scroll', onScroll);
    }, []);

    React.useEffect(() => {
        document.documentElement.style.overflow = mobileMenuOpen ? 'hidden' : '';
        return () => { document.documentElement.style.overflow = ''; };
    }, [mobileMenuOpen]);

    const navLinks = isDocsPage
        ? []
        : [
            { label: 'Cipher', href: '#cipher' },
            { label: 'Passage', href: '#passage' },
            { label: 'Agents', href: '#agents' },
            { label: 'Docs', href: '/docs/agents' },
        ];

    const handleLinkClick = (href: string) => {
        setMobileMenuOpen(false);

        if (href.startsWith('/')) {
            navigate(href);
            return;
        }

        const pageRoot = isDocsPage ? location.pathname : '/';

        if (location.pathname !== pageRoot) {
            navigate(`${pageRoot}${href}`);
            return;
        }

        const targetId = href.replace(/^#/, '');
        const node = document.getElementById(targetId);

        if (node) {
            node.scrollIntoView({ behavior: 'smooth', block: 'start' });
            window.history.replaceState(null, '', `${pageRoot}${href}`);
        }
    };

    return (
        <header
            className={[
                'vl-nav',
                scrolled ? 'is-scrolled' : '',
                isDocsPage ? 'vl-nav--docs' : '',
                mobileMenuOpen ? 'is-open' : '',
            ].join(' ')}
        >
            <div className="vl-nav-shell">
                <button className="vl-brand" onClick={() => { setMobileMenuOpen(false); navigate('/'); }} aria-label="Vibe home">
                    <BrandGlyph />
                    <span className="vl-brand-word">vibe</span>
                </button>

                {!isDocsPage && (
                    <nav className="vl-nav-links" aria-label="Primary">
                        {navLinks.map((link, i) => (
                            <button
                                key={link.label}
                                type="button"
                                className="vl-nav-link"
                                onClick={() => handleLinkClick(link.href)}
                            >
                                <span className="vl-nav-link-index">0{i + 1}</span>
                                {link.label}
                            </button>
                        ))}
                    </nav>
                )}

                <div className="vl-nav-actions">
                    {isDocsPage ? (
                        <>
                            <button className="vl-nav-ghost" onClick={() => navigate('/')}>Home</button>
                            <button className="vl-nav-cta" onClick={() => navigate('/app')}>
                                Open Vibe
                            </button>
                        </>
                    ) : (
                        <>
                            <button className="vl-nav-ghost" onClick={() => navigate('/app')}>Sign in</button>
                            <button className="vl-nav-cta" onClick={() => navigate('/app')}>
                                Open Vibe
                            </button>
                            <button
                                className="vl-nav-burger"
                                aria-label={mobileMenuOpen ? 'Close menu' : 'Open menu'}
                                aria-expanded={mobileMenuOpen}
                                onClick={() => setMobileMenuOpen((v) => !v)}
                            >
                                <span />
                                <span />
                            </button>
                        </>
                    )}
                </div>
            </div>

            {!isDocsPage && (
                <div className="vl-nav-overlay" role="dialog" aria-modal="true" aria-hidden={!mobileMenuOpen}>
                    <div className="vl-nav-overlay-links">
                        {navLinks.map((link, i) => (
                            <button key={link.label} type="button" onClick={() => handleLinkClick(link.href)}>
                                <span>0{i + 1}</span>
                                {link.label}
                            </button>
                        ))}
                        <button type="button" className="vl-nav-overlay-cta" onClick={() => { setMobileMenuOpen(false); navigate('/app'); }}>
                            Open Vibe →
                        </button>
                    </div>
                    <div className="vl-nav-overlay-meta">
                        <span>E2E · AES-256-GCM</span>
                        <span>NO PHONE NUMBER</span>
                        <span>v0.1.0-ALPHA</span>
                    </div>
                </div>
            )}
        </header>
    );
};
