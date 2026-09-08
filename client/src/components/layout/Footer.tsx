import './Footer.css';

export const Footer = () => (
    <footer className="vl-footer">
        <div className="vl-footer-grid">
            <div className="vl-footer-col">
                <span className="vl-footer-head">PRODUCT</span>
                <a href="/#cipher">Encryption</a>
                <a href="/#passage">Censorship passage</a>
                <a href="/#agents">Agent bridge</a>
            </div>
            <div className="vl-footer-col">
                <span className="vl-footer-head">BUILD</span>
                <a href="/docs/agents">Agent bridge docs</a>
                <a href="/docs/agents/config">Configuration</a>
                <a href="/docs/agents/examples">Examples</a>
            </div>
            <div className="vl-footer-col">
                <span className="vl-footer-head">LEGAL</span>
                <a href="/terms">Terms of service</a>
                <a href="/privacy">Privacy policy</a>
            </div>
            <div className="vl-footer-col">
                <span className="vl-footer-head">ENTER</span>
                <a href="/app">Open Vibe</a>
                <a href="/app">Create a key</a>
            </div>
        </div>
        <div className="vl-footer-bottom">
            <span>© 2026 Vibe</span>
            <span>v0.1.0-alpha</span>
        </div>
    </footer>
);

export default Footer;
