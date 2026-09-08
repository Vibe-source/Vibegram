import React from 'react';
import { useSearchParams, Link } from 'react-router-dom';

/**
 * OAuth browser fallback after GitHub (or other) platform connect.
 * Primary path is the iOS ASWebAuthenticationSession deep link
 * `vibe://platforms/oauth?...`; this page is for desktop / failed deep links.
 */
const ConnectorsLanding: React.FC = () => {
  const [params] = useSearchParams();
  const status = params.get('status') || '';
  const provider = params.get('provider') || 'platform';
  const login = params.get('login') || '';
  const error = params.get('error') || '';
  const success = status === 'success';

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: '#0b0b0d',
        color: '#f5f5f7',
        fontFamily: '-apple-system, system-ui, sans-serif',
        padding: 24,
      }}
    >
      <div style={{ maxWidth: 420, textAlign: 'center' }}>
        <h1 style={{ fontSize: 28, marginBottom: 12 }}>
          {success ? 'Connected' : 'Connection failed'}
        </h1>
        <p style={{ opacity: 0.8, lineHeight: 1.5 }}>
          {success
            ? `${provider}${login ? ` (@${login})` : ''} is linked to your Vibe account. Coding agents (Claude, Codex, Grok) and Vibe agents can use granted platform actions — tokens stay on the server.`
            : `Could not finish ${provider} OAuth${error ? `: ${error}` : ''}. Open the Vibe app → Settings → Connected Apps and try again.`}
        </p>
        <p style={{ marginTop: 24 }}>
          <a href="vibe://platforms/oauth" style={{ color: '#5b8cff' }}>
            Open Vibe
          </a>
          {' · '}
          <Link to="/" style={{ color: '#5b8cff' }}>
            Home
          </Link>
        </p>
        <p style={{ marginTop: 32, fontSize: 13, opacity: 0.55 }}>
          Multi-platform scheme: GitHub live; Excel, Slack, Linear, Calendar in the catalog.
          Docs: <code>docs/platform-connectors.md</code>
        </p>
      </div>
    </div>
  );
};

export default ConnectorsLanding;
