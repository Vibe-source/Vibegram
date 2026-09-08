import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@fontsource-variable/space-grotesk/index.css'
import '@fontsource-variable/jetbrains-mono/index.css'
import '@fontsource/instrument-serif/400-italic.css'
import './index.css'
import './theme/site-tokens.css'
import { applyRootTheme } from './theme/applyRootTheme'
import './theme/gsap'
import App from './App.tsx'

applyRootTheme()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
