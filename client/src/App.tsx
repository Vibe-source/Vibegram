import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import Chat from './components/Chat';
import Home from './pages/Home';
import AgentDocs from './pages/AgentDocs';
import AgentConfigDocs from './pages/AgentConfigDocs';
import AgentExamplesDocs from './pages/AgentExamplesDocs';
import AgentEnvDocs from './pages/AgentEnvDocs';
import ProviderDocs from './pages/ProviderDocs';
import ProviderQuickstartDocs from './pages/ProviderQuickstartDocs';
import ProviderPayloadDocs from './pages/ProviderPayloadDocs';
import ProviderSecurityDocs from './pages/ProviderSecurityDocs';
import ConnectorsLanding from './pages/ConnectorsLanding';

// App Wrapper to handle PWA vs Landing logic
const App = () => {
  // NUCLEAR CLEANUP: Wipe potentially poisoned storage on load
  React.useEffect(() => {
    const saved = localStorage.getItem('proxy_endpoints');
    if (saved && saved.includes('/localhost')) {
      console.warn('[APP] Detected bad endpoints in storage. clearing.');
      localStorage.removeItem('proxy_endpoints');
      localStorage.removeItem('custom_server_url');
      window.location.reload();
    }
    console.log('[APP] Running Build Version: v1.5-FIXED-TOKEN-RACE');
  }, []);

  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/docs/agents" element={<AgentDocs />} />
        <Route path="/docs/agents/config" element={<AgentConfigDocs />} />
        <Route path="/docs/agents/examples" element={<AgentExamplesDocs />} />
        <Route path="/docs/agents/env" element={<AgentEnvDocs />} />
        <Route path="/docs/providers" element={<ProviderDocs />} />
        <Route path="/docs/providers/quickstart" element={<ProviderQuickstartDocs />} />
        <Route path="/docs/providers/payloads" element={<ProviderPayloadDocs />} />
        <Route path="/docs/providers/security" element={<ProviderSecurityDocs />} />
        <Route path="/settings/connectors" element={<ConnectorsLanding />} />
        <Route path="/app" element={<Chat />} />
        {/* Catch-all redirect to Home or App depending on preference, default to Home for now */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
};

export default App;
