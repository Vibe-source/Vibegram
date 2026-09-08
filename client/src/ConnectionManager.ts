/**
 * ConnectionManager - Smart Fallback Connection System
 * 
 * Automatically rotates between multiple server endpoints when one is blocked.
 * Uses ProxyManager to manage the server list and fallback logic.
 * Integrates CensorshipBypass for regions with heavy filtering (Iran, etc.)
 */

import { Socket } from 'phoenix';
import ProxyManager, { ServerEndpoint } from './ProxyManager';
import { keyStore } from './localKeyStore';
import CensorshipBypass from './CensorshipBypass';

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error' | 'switching';

interface StatusListener {
    (status: ConnectionStatus, latency: number, endpoint: ServerEndpoint | null): void;
}

class ConnectionManager {
    private static instance: ConnectionManager;
    public socket: Socket | null = null;
    private status: ConnectionStatus = 'disconnected';
    private latency: number = 0;
    private currentEndpoint: ServerEndpoint | null = null;
    private listeners: StatusListener[] = [];
    private proxyManager: ProxyManager;

    private isAutoSwitching: boolean = false;
    private authToken: string | null = null;

    private constructor() {
        this.proxyManager = ProxyManager.getInstance();
        // CensorshipBypass is loaded on demand when needed
        CensorshipBypass.getInstance();

        // Auto-detect network changes
        if (typeof window !== 'undefined') {
            window.addEventListener('online', () => {
                console.log('[CONN] Network is ONLINE. Reconnecting...');
                this.connect();
            });
            window.addEventListener('offline', () => {
                console.log('[CONN] Network is OFFLINE.');
                this.status = 'disconnected';
                this.notify();
            });

            // Reconnect on visibility change (background -> foreground)
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible') {
                    console.log('[CONN] App background -> foreground. Verifying connection...');

                    // 1. If completely disconnected, connect immediately
                    if (this.status === 'disconnected' || !this.socket) {
                        console.log('[CONN] Status is disconnected, connecting now...');
                        this.connect();
                        return;
                    }

                    // 2. If socket exists but disconnected
                    if (this.socket && !this.socket.isConnected()) {
                        console.log('[CONN] Socket disconnected, reconnecting...');
                        this.socket.connect();
                        return;
                    }

                    // Phoenix handles heartbeats automatically, but we can keep our latency check
                }
            });
        }
    }

    public setToken(token: string) {
        this.authToken = token;
        // If already connected, do we reconnect?
        // Usually handled by caller re-initializing
    }

    public async findWorkingEndpoint() {
        return this.proxyManager.findWorkingEndpoint();
    }

    public static getInstance(): ConnectionManager {
        if (!ConnectionManager.instance) {
            ConnectionManager.instance = new ConnectionManager();
        }
        return ConnectionManager.instance;
    }

    /**
     * Get the current server URL
     */
    public getServerUrl(): string {
        let url = this.currentEndpoint?.url || this.proxyManager.getBestUrl();

        // SUPER AGGRESSIVE FIX: Remove '/localhost' from ANYWHERE in the URL for tunnels
        // This handles cases where it might be "ngrok.io/localhost/" or "ngrok.io/localhost"
        if (url && (
            url.includes('ngrok.io') ||
            url.includes('railway.app') ||
            url.includes('trycloudflare.com') ||
            url.includes('serveo.net')
        )) {
            url = url.replace(/\/localhost/g, '');
        }

        // Standard cleanup for others (trailing only)
        if (url && !url.includes('://localhost') && !url.includes('://127.0.0.1')) {
            url = url.replace(/\/localhost\/?$/, '');
        }

        // Debug log to prove we are running the new code
        // console.log('[CONN] resolved url:', url);

        return url;
    }

    /**
     * Set primary server URL (adds to ProxyManager if new)
     */
    public setServerUrl(url: string) {
        if (!url) return;
        this.proxyManager.addEndpoint(url, 'Custom Server', 'direct');
        // Find and set as current
        const endpoints = this.proxyManager.getEndpoints();
        const ep = endpoints.find(e => e.url === url || e.url === `https://${url}`);
        if (ep) {
            this.currentEndpoint = ep;
        }
        this.connect();
    }

    /**
     * Connect to the best available server with auto-fallback
     */
    public async connect(overrideToken?: string): Promise<Socket> {
        // If token provided, set it immediately
        if (overrideToken) {
            this.authToken = overrideToken;
        }

        // If no current endpoint, find one
        if (!this.currentEndpoint) {
            this.status = 'connecting';
            this.notify();

            // 1. Check User Preference First
            const savedUrl = localStorage.getItem('preferred_server');
            if (savedUrl) {
                const endpoints = this.proxyManager.getEndpoints();
                const preferred = endpoints.find(e => e.url === savedUrl);

                if (preferred) {
                    console.log(`[CONN] Trying preferred server: ${preferred.name}`);
                    const latency = await this.proxyManager.testEndpoint(preferred);
                    if (latency > 0) {
                        this.currentEndpoint = preferred;
                        return this.connectToEndpoint(this.currentEndpoint, overrideToken);
                    } else {
                        console.warn(`[CONN] Preferred server ${preferred.name} unreachable, falling back.`);
                        localStorage.removeItem('preferred_server'); // Clean up bad preference
                    }
                }
            }

            // 2. Use Smart Routing (tries direct first, then proxy for filtered regions)
            console.log('[CONN] Using smart routing...');
            const best = await this.proxyManager.smartConnect();

            if (best) {
                this.currentEndpoint = best;
                // If connected via V2Ray proxy, log it
                if (best.type === 'v2ray') {
                    console.log('[CONN] Connected via V2Ray proxy:', best.name);
                }
            } else {
                // Fallback: Try regular endpoint discovery
                const fallback = await this.proxyManager.findWorkingEndpoint();
                if (fallback) {
                    this.currentEndpoint = fallback;
                } else {
                    // Last resort: try first endpoint anyway
                    const endpoints = this.proxyManager.getEndpoints();
                    if (endpoints.length > 0) {
                        this.currentEndpoint = endpoints[0];
                    }
                }
            }
        }

        return this.connectToEndpoint(this.currentEndpoint, overrideToken);
    }

    /**
     * Connect to a specific endpoint
     */
    public async connectToEndpoint(endpoint: ServerEndpoint | null, overrideToken?: string): Promise<Socket> {
        if (this.socket) {
            this.socket.disconnect();
            this.socket = null;
        }

        if (overrideToken) {
            this.authToken = overrideToken;
        }

        if (!endpoint) {
            this.status = 'error';
            this.notify();
            console.error('[CONN] No endpoint available');
            return null as any;
        }

        this.currentEndpoint = endpoint;
        this.status = 'connecting';
        this.notify();

        let baseUrl = endpoint.url;

        // Sanitize URL - centralized logic is in ProxyManager, but we apply immediate fix here too
        // 1. Remove /localhost from tunnels
        if (baseUrl.includes('ngrok.io/localhost') || baseUrl.includes('trycloudflare.com/localhost') || baseUrl.includes('railway.app/localhost')) {
            baseUrl = baseUrl.replace(/\/localhost/g, '');
        }

        // 2. Remove :80 from Railway/HTTPS URLs
        if ((baseUrl.includes('railway.app') || baseUrl.startsWith('https://')) && baseUrl.includes(':80')) {
            baseUrl = baseUrl.replace(':80', '');
        }

        // 3. Strip trailing slash
        baseUrl = baseUrl.replace(/\/$/, "");

        // 4. Force HTTPS (unless localhost)
        if (baseUrl.startsWith('http://') && !baseUrl.includes('localhost') && !baseUrl.includes('127.0.0.1')) {
            baseUrl = baseUrl.replace('http://', 'https://');
        }

        console.log(`[CONN] Connection attempt for: ${baseUrl}`);

        let socketUrl = baseUrl.replace("http://", "ws://").replace("https://", "wss://");
        socketUrl = socketUrl.endsWith("/") ? socketUrl + "socket" : socketUrl + "/socket";

        try {
            // Ensure we have a token if possible
            if (!this.authToken) {
                const session = await keyStore.loadSession();
                if (session && session.loginToken) {
                    this.authToken = session.loginToken;
                }
            }
        } catch (e) {
            console.warn('[CONN] Session retrieval failed:', e);
        }

        if (!this.authToken) {
            console.warn('[CONN] No auth token available during connect(). Delaying socket connection until login.');
            this.status = 'disconnected';
            this.notify();
            return null as any;
        }

        console.log(`[CONN] Connecting to Phoenix at: ${socketUrl}`);
        console.log(`[CONN] Using Auth Token (hasToken=true, len=${this.authToken.length})`);

        this.socket = new Socket(socketUrl, {
            params: { token: this.authToken }
        });

        this.socket.connect();
        this.setupSocketListeners();
        return this.socket;
    }

    /**
     * Setup socket event listeners with smart fallback
     */
    private setupSocketListeners() {
        if (!this.socket) return;

        this.socket.onOpen(async () => {
            console.log('[CONN] Socket connected (Phoenix)');
            this.status = 'connected';

            this.isAutoSwitching = false;

            // Update endpoint status
            if (this.currentEndpoint) {
                this.currentEndpoint.status = 'online';
                this.latency = await this.measureLatency();
                this.currentEndpoint.lastLatency = this.latency;
            }

            // Start heartbeat - Phoenix has built-in, but we might keep ours for app-level checks?
            // Actually Phoenix handles regular heartbeats correctly.
            // We can rely on onOpen/onClose.

            this.notify();
        });

        this.socket.onClose((e) => {
            console.log(`[CONN] Socket disconnected. Code: ${e.code}, Reason: ${e.reason}, WasClean: ${e.wasClean}`, e);
            this.status = 'disconnected';
            this.latency = 0;
            this.notify();

            // If unexpected close, might want to trigger fallback?
            // Phoenix client auto-reconnects.
            // If it fails repeatedly, we might want to switch server.
            // For now, let Phoenix handle reconnect backoff.
        });

        this.socket.onError((e) => {
            console.log('[CONN] Socket Error Details:', e);
            // Check if transport error
            if (this.socket && (this.socket as any).transport) {
                console.log('[CONN] Transport state:', (this.socket as any).transport);
            }
            this.status = 'error';
            this.notify();
            // Could trigger switch if persistent
        });
    }

    /**
     * Handle connection failure - try next server
     */
    public async handleConnectionFailure() {
        if (this.isAutoSwitching) return;
        this.isAutoSwitching = true;

        // Mark current as failed
        if (this.currentEndpoint) {
            this.currentEndpoint.status = 'blocked';
        }

        this.status = 'switching';
        this.notify();



        // Get all endpoints and find next working one
        const endpoints = this.proxyManager.getEndpoints();
        const currentIndex = endpoints.findIndex(e => e.url === this.currentEndpoint?.url);

        // Try endpoints in order, starting from next one
        for (let i = 1; i <= endpoints.length; i++) {
            const nextIndex = (currentIndex + i) % endpoints.length;
            const nextEndpoint = endpoints[nextIndex];

            if (nextEndpoint.url === this.currentEndpoint?.url) continue;



            // Quick check if server is reachable
            const latency = await this.proxyManager.testEndpoint(nextEndpoint);

            if (latency > 0) {


                this.isAutoSwitching = false;
                this.connectToEndpoint(nextEndpoint);
                return;
            }
        }

        // All servers failed - retry in loop
        console.error('[CONN] All servers unreachable! Retrying in 5s...');
        this.status = 'error';
        this.notify();

        setTimeout(() => {
            console.log('[CONN] Auto-reconnecting...');
            this.scanAndConnect();
        }, 5000);
    }

    /**
     * Measure latency to current server
     */
    private async measureLatency(): Promise<number> {
        if (!this.currentEndpoint) return 0;

        let url = this.currentEndpoint.url;
        if (typeof window !== 'undefined' && window.location.protocol === 'https:' && url.startsWith('http:')) {
            url = url.replace('http:', 'https:');
        }

        const start = Date.now();
        try {
            const res = await fetch(`${url}/api/health`, {
                method: 'GET',
                cache: 'no-store', // Standard way to bypass cache without custom headers
                signal: AbortSignal.timeout(5000)
            });
            if (!res.ok) return -1;
            return Date.now() - start;
        } catch {
            return -1;
        }
    }

    /**
     * Force switch to a specific endpoint
     */
    public switchToEndpoint(endpoint: ServerEndpoint) {

        // Save preference
        localStorage.setItem('preferred_server', endpoint.url);
        this.connectToEndpoint(endpoint);
    }

    /**
     * Scan all servers and connect to the best one
     */
    public async scanAndConnect(): Promise<ServerEndpoint | null> {
        this.status = 'connecting';
        this.notify();

        const best = await this.proxyManager.scanAllEndpoints();

        if (best) {

            this.connectToEndpoint(best);
        } else {
            this.status = 'error';
            this.notify();
        }

        return best;
    }

    public getSocket(): Socket | null {
        return this.socket;
    }

    public getStatus() {
        return {
            status: this.status,
            latency: this.latency,
            endpoint: this.currentEndpoint
        };
    }

    public getCurrentEndpoint(): ServerEndpoint | null {
        return this.currentEndpoint;
    }

    public subscribe(cb: StatusListener) {
        this.listeners.push(cb);
        cb(this.status, this.latency, this.currentEndpoint);
        return () => {
            this.listeners = this.listeners.filter(l => l !== cb);
        };
    }

    private notify() {
        this.listeners.forEach(cb => cb(this.status, this.latency, this.currentEndpoint));
    }

    /**
     * Force reconnect - useful for manual recovery
     */
    public forceReconnect(token?: string) {
        console.log('[CONN] Force reconnect requested');

        if (token) {
            console.log('[CONN] Setting explicit token via forceReconnect');
            this.authToken = token;
            this.connect(token);
            return;
        }

        this.connect();
    }
}

export default ConnectionManager;
