import { useState, useEffect, useRef, } from 'react';
import { Socket, Channel } from 'phoenix';
import { motion, AnimatePresence, } from 'framer-motion';
import {
  CheckCheck, AlertCircle, Phone, X
} from 'lucide-react';
import Haptics from '../haptics';
import ConnectionManager from '../ConnectionManager';
import P2PManager from '../P2PManager';
import ConnectionPage from '../ConnectionPage';
import Auth from './Auth';
import Home from './Home';
import ActiveChat from './ActiveChat';
import ContactInfo from './ContactInfo';
import Profile from './Profile';
import NewChatModal from './NewChatModal';
import CallOverlay from './CallOverlay';

import '../Chat.css';
import '../ProfileStyles.css';
import { Chat, Message } from '../types';
import { getApiUrl } from '../utils';
import { MediaConnection } from 'peerjs';
import {
  importPublicKey,
  decryptMessage, generateAESKey, exportAESKey,
  encryptFile, decryptFile, importAESKey,
  encryptMessage, importKeyPair
} from '../crypto';

/* --- Helper Utils (Keep strictly internal if not exported) --- */
const urlBase64ToUint8Array = (base64String: string) => {
  const padding = '='.repeat((4 - base64String.length % 4) % 4);
  const base64 = (base64String + padding).replace(/\-/g, '+').replace(/_/g, '/');
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
};

// --- Obfuscation Helpers ---
const generateNoise = (len = 32) => {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  for (let i = 0; i < len; i++) result += chars.charAt(Math.floor(Math.random() * chars.length));
  return result;
  return result;
};

// Simplify obfuscation for Phoenix compatibility initially if needed, logic here is unchanged for now
const obfuscatePayload = (data: any) => {
  const json = JSON.stringify(data);
  const bytes = new TextEncoder().encode(json);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return {
    _t: Date.now(),
    _n: generateNoise(16 + Math.floor(Math.random() * 48)),
    _v: '1.0',
    d: btoa(binary)
  };
};

const deobfuscatePayload = (wrapped: any) => {
  try {
    if (wrapped && wrapped.d) {
      const binary = atob(wrapped.d);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      return JSON.parse(new TextDecoder().decode(bytes));
    }
  } catch (e) { console.error('Deobfuscate failed', e); }
  return wrapped;
};

// From Mobile ChatStore logic
const normalizeMessage = (m: any): Message => {
  return {
    id: m.id || m.message_id,
    fromId: m.fromId || m.from_id,
    encryptedContent: m.encryptedContent || m.encrypted_content,
    type: m.type || 'text',
    timestamp: typeof m.timestamp === 'string' ? new Date(m.timestamp).getTime() : (m.timestamp || Date.now()),
    plaintext: m.plaintext || m._senderPlaintext || m.sender_plaintext,
    status: m.status || 'sent',
    mediaUrl: m.mediaUrl || m.media_url,
    metadata: m.metadata,
    replyToId: m.replyToId || m.reply_to_id,
    readBy: m.readBy || m.read_by || []
  };
};

// Use centralized key store for session management
import { keyStore } from '../localKeyStore';
import { privacySettings } from '../privacySettings';

// Load session from the unified key store and attempt to load cached chats
const loadSession = async (): Promise<{ session: any | null, cachedChats: Chat[] }> => {
  try {
    const session = await keyStore.loadSession();
    let cachedChats: Chat[] = [];
    if (session && session.userId) {
      try {
        const raw = localStorage.getItem(`vibe_chats_${session.userId}`);
        if (raw) {
          cachedChats = JSON.parse(raw);
          console.log(`[Cache] Loaded ${cachedChats.length} chats from local storage`);
        }
      } catch (e) {
        console.warn('[Cache] Failed to load local chats', e);
      }
    }
    return { session, cachedChats };
  } catch {
    return { session: null, cachedChats: [] };
  }
};



// We will change the signature of saveChatsToDB to accept userId
const saveChatsToLocalStorage = (chats: Chat[], userId: string) => {
  try {
    // Limit cache size? Text is cheap. 
    localStorage.setItem(`vibe_chats_${userId}`, JSON.stringify(chats));
  } catch (e) {
    console.warn('[Cache] Full or invalid', e);
  }
};

export default function ChatComponent() {
  const [socket, setSocket] = useState<Socket | null>(null);
  const [userChannel, setUserChannel] = useState<Channel | null>(null);
  const [chatChannels, setChatChannels] = useState<Map<string, Channel>>(new Map());

  const [userId, setUserId] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [username, setUsername] = useState('');
  const [keys, setKeys] = useState<CryptoKeyPair | null>(null);
  const [, setLoginToken] = useState<string | null>(null);

  const [view, setView] = useState<'loading' | 'auth' | 'chats' | 'chat' | 'connection' | 'profile' | 'contact' | 'call'>('loading');
  const [direction, setDirection] = useState(0);

  const viewOrder: Record<string, number> = {
    'auth': 0,
    'chats': 1,
    'chat': 2,
    'contact': 3,
    'profile': 3, // Profile on same level as contact (modal-like)
    'connection': 3
  };

  const handleViewChange = (newView: string) => {
    const currentOrder = viewOrder[view] || 0;
    const newOrder = viewOrder[newView] || 0;

    // Explicit back navigation logic (e.g. going from Contact back to Chat)
    if (newOrder > currentOrder) {
      setDirection(1); // Forward
    } else if (newOrder < currentOrder) {
      setDirection(-1); // Backward
    } else {
      setDirection(0); // No transition or neutral
    }

    if (newView === 'chats') {
      setActiveChat(null);
    }
    setView(newView as any);
  };

  const variants = {
    initial: (direction: number) => ({ x: direction > 0 ? '100%' : '-100%' }),
    animate: { x: 0 },
    exit: (direction: number) => ({ x: direction < 0 ? '100%' : '-100%' })
  };

  // Haptic Ring Logic
  const ringInterval = useRef<any>(null);

  // Call State
  const [incomingCall, setIncomingCall] = useState<{ fromId: string, call: MediaConnection, isVideo?: boolean } | null>(null);
  const [isCalling, setIsCalling] = useState(false);
  const [isVideoCall, setIsVideoCall] = useState(false);
  const [callStream, setCallStream] = useState<MediaStream | null>(null);
  const [remoteStream, setRemoteStream] = useState<MediaStream | null>(null);
  const [activeCall, setActiveCall] = useState<MediaConnection | null>(null);
  const [isMuted, setIsMuted] = useState(false);
  const [isVideoEnabled, setIsVideoEnabled] = useState(true);

  // Join Request State
  const [joinRequests, setJoinRequests] = useState<Array<{ odId: string, fromName: string, fromImage?: string, isVideo: boolean }>>([]);
  const [isJoinRequestPending, setIsJoinRequestPending] = useState(false);

  // Sync refs for event handlers (avoid stale closures in socket listeners)
  const incomingCallRef = useRef<{ fromId: string, call: MediaConnection } | null>(null);
  const isCallingRef = useRef(false);
  const activeCallRef = useRef<MediaConnection | null>(null);
  useEffect(() => { isCallingRef.current = isCalling; }, [isCalling]);
  useEffect(() => { activeCallRef.current = activeCall; }, [activeCall]);

  // Persist chats to local storage whenever they change


  // Initialize P2P Call Listeners
  useEffect(() => {
    const unsub = P2PManager.getInstance().onCall((call) => {
      console.log("Incoming P2P Call from", call.peer, "metadata:", call.metadata);
      const fromId = call.peer.replace('SC_V1_', '');
      const isVideoCall = call.metadata?.isVideo === true;
      setIncomingCall({ fromId, call, isVideo: isVideoCall });
      setIsVideoCall(isVideoCall); // Set video state for incoming call
      Haptics.ring();
      ringInterval.current = setInterval(() => Haptics.ring(), 2500);

      // Listen for caller hanging up (Missed Call)
      call.on('close', () => {
        if (incomingCallRef.current && incomingCallRef.current.call === call) {
          console.log("Incoming call closed by caller - Missed Call");
          setIncomingCall(null);
          // Trigger "Missed Call" message
          addCallMessage('missed', undefined, fromId);
        }
      });

      call.on('error', (err) => {
        console.error("Incoming call error:", err);
        if (incomingCallRef.current && incomingCallRef.current.call === call) {
          setIncomingCall(null);
        }
      });
    });
    return () => {
      unsub();
      if (ringInterval.current) clearInterval(ringInterval.current);
    };
  }, []);

  // Stop ringing when call is answered or rejected
  useEffect(() => {
    if (!incomingCall && ringInterval.current) {
      clearInterval(ringInterval.current);
      ringInterval.current = null;
    }
  }, [incomingCall]);

  // Call Handlers
  const startCall = async (friendId: string, video: boolean) => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: video, audio: true });
      setCallStream(stream);
      setIsVideoCall(video);
      setIsVideoEnabled(video);
      setIsMuted(false);
      setIsCalling(true);

      const call = P2PManager.getInstance().call(friendId, stream, video);

      // Emit socket signal regardless of P2P success (Fallback/Parallel)
      if (activeChat?.friendId) {
        const upperFriendId = activeChat.friendId.toUpperCase();
        console.log(`[CALL] Emitting socket signal to ${upperFriendId}`);
        userChannelRef.current?.push('call-start', { toUserId: upperFriendId, isVideo: video });
      }

      if (call) {
        setupCallEvents(call);
      } else {
        console.log("P2P unavailable, using socket fallback");
      }
    } catch (e) {
      console.error("Media Error", e);
      setToast("Microphone/Camera access required");
    }
  };

  const acceptCall = async (withVideo: boolean = false) => {
    if (!incomingCall) return;
    try {
      // Request media based on call type
      const stream = await navigator.mediaDevices.getUserMedia({ video: withVideo, audio: true });
      setCallStream(stream);
      setIncomingCall(null);
      setIsCalling(true);
      setIsVideoCall(withVideo);
      setIsVideoEnabled(withVideo);

      incomingCall.call.answer(stream);
      setupCallEvents(incomingCall.call);
    } catch (e) {
      console.error("Accept Error", e);
      setToast("Failed to access media");
    }
  };

  const rejectCall = () => {
    if (incomingCall) {
      addCallMessage('rejected', undefined, incomingCall.fromId);
      incomingCall.call.close();
      setIncomingCall(null);
    }
  };

  /* -- Call Logic -- */
  const callStartTimeRef = useRef<number>(0);

  const addCallMessage = (status: 'ended' | 'missed' | 'rejected', durationStr?: string, targetFriendId?: string) => {
    if (!userId) return;
    const fId = targetFriendId || (activeChat ? activeChat.friendId : null);
    if (!fId) return;

    // Find the chat object
    const targetChat = chats.find(c => c.friendId === fId) || (activeChat?.friendId === fId ? activeChat : null);
    if (!targetChat) return;

    const tempId = crypto.randomUUID();
    const callMsg: Message = {
      id: tempId,
      // If 'missed', it appears as if THEY called us. 
      // If 'rejected', it appears as if WE rejected (so from US).
      // If 'ended', usually from US (system info).
      fromId: status === 'missed' ? fId : userId,
      type: 'call',
      encryptedContent: '',
      plaintext: JSON.stringify({ status, duration: durationStr }),
      timestamp: Date.now(),
      status: 'read'
    };

    setChats(prev => prev.map(c => c.chatId === targetChat.chatId ? {
      ...c,
      messages: [...c.messages, callMsg],
      unreadCount: (status === 'missed' && activeChat?.chatId !== c.chatId) ? (c.unreadCount || 0) + 1 : c.unreadCount
    } : c));

    // Update active chat if it matches
    if (activeChat && activeChat.chatId === targetChat.chatId) {
      setActiveChat(prev => prev ? ({ ...prev, messages: [...prev.messages, callMsg] }) : null);
    }
  };

  const endCall = () => {
    activeCall?.close();
    callStream?.getTracks().forEach(t => t.stop());

    // Calculate duration
    let durationStr = '';
    if (callStartTimeRef.current > 0) {
      const diff = Math.floor((Date.now() - callStartTimeRef.current) / 1000);
      const mins = Math.floor(diff / 60);
      const secs = diff % 60;
      durationStr = `${mins}:${secs.toString().padStart(2, '0')}`;
    }

    addCallMessage('ended', durationStr);

    setActiveCall(null);
    setCallStream(null);
    setRemoteStream(null);
    setIsCalling(false);
  };

  const setupCallEvents = (call: MediaConnection) => {
    setActiveCall(call);
    call.on('stream', (stream) => {
      setRemoteStream(stream);
    });
    call.on('close', () => {
      endCall();
      setToast("Call Ended");
      setTimeout(() => setToast(null), 3000);
    });
    call.on('error', () => {
      endCall();
      setToast("Call Error");
    });
  };

  const toggleMuteLocal = () => {
    if (callStream) {
      const track = callStream.getAudioTracks()[0];
      if (track) {
        track.enabled = !track.enabled;
        setIsMuted(!track.enabled);
      }
    }
  };

  const toggleVideoLocal = () => {
    if (callStream) {
      const track = callStream.getVideoTracks()[0];
      if (track) {
        track.enabled = !track.enabled;
        setIsVideoEnabled(track.enabled);
      }
    }
  };

  const toggleCamera = async () => {
    if (!callStream) return;
    const currentVidTrack = callStream.getVideoTracks()[0];
    if (!currentVidTrack) return;

    // Get all video devices
    const devices = await navigator.mediaDevices.enumerateDevices();
    const videoDevices = devices.filter(d => d.kind === 'videoinput');
    if (videoDevices.length < 2) return; // Can't switch if only 1

    const currentSettings = currentVidTrack.getSettings();
    const currentDeviceId = currentSettings.deviceId;

    // Find next device
    let nextDevice = videoDevices[0];
    const idx = videoDevices.findIndex(d => d.deviceId === currentDeviceId);
    if (idx !== -1 && idx < videoDevices.length - 1) {
      nextDevice = videoDevices[idx + 1];
    }

    try {
      const newStream = await navigator.mediaDevices.getUserMedia({
        video: { deviceId: { exact: nextDevice.deviceId } },
        audio: false // handle audio separately or keep existing
      });
      const newTrack = newStream.getVideoTracks()[0];

      // Replace track in stream
      callStream.removeTrack(currentVidTrack);
      callStream.addTrack(newTrack);

      // Replace track in peer connection
      if (activeCall && activeCall.peerConnection) {
        const senders = activeCall.peerConnection.getSenders();
        const sender = senders.find(s => s.track?.kind === 'video');
        if (sender) sender.replaceTrack(newTrack);
      }

      // Cleanup old track
      currentVidTrack.stop();

      // Ensure enabled state matches UI
      newTrack.enabled = isVideoEnabled;

    } catch (e) {
      console.error("Failed to switch camera", e);
      setToast("Camera switch failed");
    }
  };

  // Join Request Handlers
  const sendJoinRequest = () => {
    if (!userChannelRef.current || !activeChat || isJoinRequestPending) return;

    userChannelRef.current.push('call-join-request', {
      toUserId: activeChat.friendId,
      fromUserId: userId,
      fromName: 'You', // The receiver will see their friend's name
      isVideo: isVideoCall
    });
    setIsJoinRequestPending(true);
    setToast('Join request sent...');
    setTimeout(() => setToast(null), 2000);
  };

  const acceptJoinRequest = (fromId: string) => {
    if (!userChannelRef.current) return;
    userChannelRef.current.push('call-join-accepted', {
      toUserId: fromId,
      fromUserId: userId
    });
    // Remove from pending requests
    setJoinRequests(prev => prev.filter(r => r.odId !== fromId));
  };

  const rejectJoinRequest = (fromId: string) => {
    if (!userChannelRef.current) return;
    userChannelRef.current.push('call-join-rejected', {
      toUserId: fromId,
      fromUserId: userId
    });
    // Remove from pending requests
    setJoinRequests(prev => prev.filter(r => r.odId !== fromId));
  };

  const [chats, setChats] = useState<Chat[]>([]);
  const chatsRef = useRef<Chat[]>([]);
  useEffect(() => { chatsRef.current = chats; }, [chats]);
  // Persist chats to local storage whenever they change
  useEffect(() => {
    if (userId && chats.length > 0) {
      saveChatsToLocalStorage(chats, userId);
    }
  }, [chats, userId]);
  const [areChatsLoading, setAreChatsLoading] = useState(true);
  const [activeChat, setActiveChat] = useState<Chat | null>(null);

  // Sync activeChat when chats update (e.g. from background refresh)
  useEffect(() => {
    if (activeChat) {
      const updated = chats.find(c => c.chatId === activeChat.chatId);
      if (updated && updated !== activeChat) setActiveChat(updated);
    }
  }, [chats]);

  const [showNewChatModal, setShowNewChatModal] = useState(false);
  const [lightboxImage, setLightboxImage] = useState<string | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [ctxMenu, setCtxMenu] = useState<{ x: number, y: number, m: Message } | null>(null);
  const [isEditing, setIsEditing] = useState(false);

  // Contact Info states
  const [contactSearchQuery, setContactSearchQuery] = useState('');
  const [showContactSearch, setShowContactSearch] = useState(false);

  // Monitor Connection & Rejoin Channels on Reconnect
  useEffect(() => {
    const manager = ConnectionManager.getInstance();
    const unsub = manager.subscribe((status) => {
      if (status === 'connected') {
        const newSocket = manager.getSocket();
        // If socket instance changed (reconnection), we MUST rejoin channels
        if (newSocket && socketRef.current !== newSocket) {
          console.log('[Chat] Socket instance changed, rejoining channels...');
          socketRef.current = newSocket;

          if (userId) {
            joinUserChannel(userId, newSocket);
            // Rejoin all currently loaded chats to ensure real-time events
            chatsRef.current.forEach(c => joinChatChannel(c.chatId, newSocket));
          }
        }
      }
    });
    return () => unsub();
  }, [userId]);

  const [message, setMessage] = useState('');
  // Decrypted Cache
  const [decryptedMessages, setDecryptedMessages] = useState<Record<string, string>>({});
  const [decryptedMedia, setDecryptedMedia] = useState<Record<string, string>>({});
  // Track messages that failed decryption due to key mismatch
  const [hasUndecryptableMessages, setHasUndecryptableMessages] = useState(false);

  // Media State
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [mediaPreview, setMediaPreview] = useState<string | null>(null);


  const [connectionStatus, setConnectionStatus] = useState<'connected' | 'disconnected' | 'reconnecting' | 'connecting' | 'error' | 'switching'>('disconnected');
  const [currentServerName, setCurrentServerName] = useState<string>('');
  const [typingUsers, setTypingUsers] = useState<Set<string>>(new Set());
  const [onlineUsers, setOnlineUsers] = useState<Set<string>>(new Set());

  const [chatOptionsChat, setChatOptionsChat] = useState<Chat | null>(null);
  const [replyingTo, setReplyingTo] = useState<Message | null>(null);
  const [editingMessage, setEditingMessage] = useState<Message | null>(null);

  // Typing logic
  const typingTimeoutRef = useRef<any>(null);

  const handleTyping = () => {
    if (!activeChat || !userId || !socket) return;

    // Respect privacy setting - don't send typing indicators if disabled
    if (!privacySettings.canShowTyping()) return;

    const channel = chatChannelsRef.current.get(activeChat.chatId);
    channel?.push('typing', { chatId: activeChat.chatId, userId });

    if (typingTimeoutRef.current) clearTimeout(typingTimeoutRef.current);
    typingTimeoutRef.current = setTimeout(() => {
      channel?.push('stop-typing', { chatId: activeChat.chatId, userId });
    }, 3000);
  };

  const [, setNow] = useState(Date.now());

  useEffect(() => {
    const interval = setInterval(() => setNow(Date.now()), 60000);
    return () => clearInterval(interval);
  }, []);

  const messagesEndRef = useRef<HTMLDivElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const activeChatRef = useRef<Chat | null>(null);
  const socketRef = useRef<Socket | null>(null);
  const userIdRef = useRef<string | null>(null);
  const keysRef = useRef<CryptoKeyPair | null>(null);

  // Keep refs in sync
  useEffect(() => { socketRef.current = socket; }, [socket]);
  useEffect(() => { userIdRef.current = userId; }, [userId]);
  useEffect(() => { keysRef.current = keys; }, [keys]);

  // Voice Recording State
  const [isRecording, setIsRecording] = useState(false);
  const [recordingTime, setRecordingTime] = useState(0);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const recordingStatusRef = useRef<'idle' | 'starting' | 'recording' | 'stopping' | 'cancelling'>('idle');
  const audioChunksRef = useRef<Blob[]>([]);
  const recordingTimerRef = useRef<any>(null);

  // Refs
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const chatChannelsRef = useRef<Map<string, Channel>>(new Map());
  const userChannelRef = useRef<Channel | null>(null);

  useEffect(() => { chatChannelsRef.current = chatChannels; }, [chatChannels]);
  useEffect(() => { userChannelRef.current = userChannel; }, [userChannel]);

  const joinUserChannel = (uid: string, s: Socket) => {
    if (!s || !s.isConnected()) return;
    const topic = `user:${uid}`;
    const channel = s.channel(topic, {});

    // -- Voice Stream --
    channel.on('voice-stream', async ({ chunk }) => {
      if (!chunk) return;
      const playChunk = async (blob: Blob) => new Promise<void>((resolve) => {
        const audio = new Audio(URL.createObjectURL(blob));
        audio.onended = () => resolve();
        audio.play().catch(e => { console.error("Audio play failed", e); resolve(); });
      });
      if (!(window as any).audioStreamQueue) (window as any).audioStreamQueue = [];
      const blob = new Blob([chunk], { type: 'audio/webm;codecs=opus' });
      (window as any).audioStreamQueue.push(blob);
      if (!(window as any).isPlayingStream) {
        (window as any).isPlayingStream = true;
        while ((window as any).audioStreamQueue.length > 0) {
          const nextBlob = (window as any).audioStreamQueue.shift();
          if (nextBlob) await playChunk(nextBlob);
        }
        (window as any).isPlayingStream = false;
      }
    });

    // -- User Status / Presence --
    // -- User Status / Presence --
    // Handle 'friend-online' (Matches Mobile App behavior)
    channel.on('friend-online', ({ userId: statusId }) => {
      const normId = (statusId || '').toUpperCase();
      setOnlineUsers(prev => {
        const next = new Set(prev);
        next.add(normId);
        return next;
      });
    });

    // Handle 'friend-offline'
    channel.on('friend-offline', ({ userId: statusId }) => {
      const normId = (statusId || '').toUpperCase();
      setOnlineUsers(prev => {
        const next = new Set(prev);
        next.delete(normId);
        return next;
      });
    });

    // Legacy/Generic user-status support
    channel.on('user-status', ({ userId: statusId, status }) => {
      const normId = (statusId || '').toUpperCase();
      setOnlineUsers(prev => {
        const next = new Set(prev);
        if (status === 'online') next.add(normId);
        else next.delete(normId);
        return next;
      });
    });

    channel.on('initial-presence', (resp: any) => {
      // Check both activeUserIds (legacy) and onlineFriendIds (mobile standard)
      const ids = resp.activeUserIds || resp.onlineFriendIds || [];
      if (ids && Array.isArray(ids)) {
        setOnlineUsers(new Set(ids.map((id: string) => id.toUpperCase())));
      }
    });

    // -- Call Signals --
    channel.on('call-start', ({ fromUserId, isVideo }) => {
      const upperFromId = (fromUserId || '').toUpperCase();
      setIncomingCall(prev => {
        if (prev || activeCallRef.current) return prev;
        const dummyCall: any = {
          peer: `SC_V1_${upperFromId}`,
          metadata: { isVideo },
          answer: (_stream: MediaStream) => {
            channel.push("call-accepted", { toUserId: upperFromId });
          },
          close: () => { }, on: () => { }, off: () => { }
        };
        return { fromId: upperFromId, isVideo, call: dummyCall };
      });
    });
    channel.on('call-accepted', ({ fromUserId }) => {
      if (isCallingRef.current && !activeCallRef.current) {
        setToast("Call Answered");
        callStartTimeRef.current = Date.now();
        const dummyCall: any = {
          peer: `SC_V1_${fromUserId}`,
          close: () => {
            channel.push("call-end", { toUserId: fromUserId });
            setActiveCall(null); setIsCalling(false);
          },
          on: () => { }, off: () => { }
        };
        setActiveCall(dummyCall);
      }
    });
    channel.on('call-join-request', ({ fromId, fromName, fromImage, isVideo }) => {
      setJoinRequests(prev => {
        if (prev.some(r => r.odId === fromId)) return prev;
        return [...prev, { odId: fromId, fromName, fromImage, isVideo }];
      });
      Haptics.soft();
    });
    // Call status events
    channel.on('call-join-accepted', ({ fromId }) => {
      setIsJoinRequestPending(false);
      setToast('Join request accepted! Starting call...');
      setTimeout(() => setToast(null), 2000);
      startCall(fromId, false); // Default to audio if not specified
    });
    channel.on('call-join-rejected', () => {
      setIsJoinRequestPending(false);
      setToast('Join request declined'); setTimeout(() => setToast(null), 2000);
    });
    channel.on('call-status', ({ message }) => {
      if (message === 'ringing_push') { setToast("Ringing..."); setTimeout(() => setToast(null), 2000); }
    });
    channel.on('call-error', ({ message }) => {
      setToast(message || 'Call failed');
      if (message !== 'User unreachable') endCall();
    });

    // --- New Chat / Message Notifications (Real-time List Updates) ---
    channel.on('new_chat', (payload) => {
      console.log('[UserChannel] New chat created:', payload);
      if (userIdRef.current) loadChats(userIdRef.current);
    });

    channel.on('new_message', (payload) => {
      console.log('[UserChannel] New message notification:', payload);
      const chatId = payload.chatId || payload.chat_id;
      const hasChat = chatsRef.current.some(c => c.chatId === chatId);

      if (!hasChat) {
        console.log('[UserChannel] New chat detected via message, reloading...');
        if (userIdRef.current) loadChats(userIdRef.current);
        Haptics.soft();
      } else {
        // Ensure we are joined to the chat channel
        if (!chatChannelsRef.current.has(chatId) && socketRef.current?.isConnected()) {
          joinChatChannel(chatId, socketRef.current);
        }
      }
    });

    channel.join()
      .receive("ok", () => console.log(`[Phoenix] Joined ${topic} successfully`))
      .receive("error", resp => console.error(`[Phoenix] Unable to join ${topic}`, resp));

    setUserChannel(channel);
    return channel;
  };

  const joinChatChannel = (chatId: string, s: Socket, onJoined?: (channel: any) => void) => {
    if (!s || !s.isConnected()) return null;
    // Allow re-joining if we have a new socket but cleared the map
    if (chatChannelsRef.current.has(chatId)) {
      // Already have this channel - call callback immediately if provided
      const existingChannel = chatChannelsRef.current.get(chatId);
      if (onJoined && existingChannel) onJoined(existingChannel);
      return existingChannel;
    }

    const topic = `chat:${chatId}`;
    const channel = s.channel(topic, {});

    channel.on("message", (payload) => {
      handleSocketMessage({ ...payload, chatId });
    });

    // Typing
    channel.on("typing", ({ userId: typistId }) => {
      const normTypist = (typistId || '').toUpperCase();
      const myId = (userIdRef.current || '').toUpperCase();
      if (normTypist !== myId) setTypingUsers(prev => new Set(prev).add(normTypist));
    });
    channel.on("stop-typing", ({ userId: typistId }) => {
      const normTypist = (typistId || '').toUpperCase();
      setTypingUsers(prev => {
        const next = new Set(prev);
        next.delete(normTypist);
        return next;
      });
    });

    // Read/Delivered/Edited/Deleted
    channel.on("message-read", ({ messageId, readerId }) => {
      const updateRead = (list: Chat[]) => list.map(c => {
        if (c.chatId === chatId) {
          return { ...c, messages: c.messages.map(m => m.id === messageId ? { ...m, status: 'read' as const, readBy: [...(m.readBy || []), readerId] } : m) };
        }
        return c;
      });
      setChats(prev => updateRead(prev));
      setActiveChat(prev => prev && prev.chatId === chatId ? { ...prev, messages: prev.messages.map(m => m.id === messageId ? { ...m, status: 'read' as const } : m) } : prev);
    });

    channel.on("message-delivered", ({ messageId }) => {
      const updateDelivered = (list: Chat[]) => list.map(c => {
        if (c.chatId === chatId) {
          return { ...c, messages: c.messages.map(m => (m.id === messageId && m.status !== 'read') ? { ...m, status: 'delivered' as const } : m) };
        }
        return c;
      });
      setChats(prev => updateDelivered(prev));
      setActiveChat(prev => prev && prev.chatId === chatId ? { ...prev, messages: prev.messages.map(m => (m.id === messageId && m.status !== 'read') ? { ...m, status: 'delivered' as const } : m) } : prev);
    });

    channel.on("message-deleted", ({ messageId }) => {
      const updateDelete = (list: Chat[]) => list.map(c => {
        if (c.chatId === chatId) {
          return { ...c, messages: c.messages.filter(m => m.id !== messageId) };
        }
        return c;
      });
      setChats(prev => updateDelete(prev));
      setActiveChat(prev => prev && prev.chatId === chatId ? { ...prev, messages: prev.messages.filter(m => m.id !== messageId) } : prev);
    });

    channel.on("message-edited", ({ messageId, encryptedContent }) => {
      const updateEdit = (list: Chat[]) => list.map(c => {
        if (c.chatId === chatId) {
          return { ...c, messages: c.messages.map(m => m.id === messageId ? { ...m, encryptedContent } : m) };
        }
        return c;
      });
      setChats(prev => updateEdit(prev));
      setActiveChat(prev => {
        if (prev && prev.chatId === chatId) {
          const newMsgs = prev.messages.map(m => m.id === messageId ? { ...m, encryptedContent } : m);
          if (keysRef.current?.privateKey) {
            const m = prev.messages.find(msg => msg.id === messageId);
            const isMe = (m?.fromId || '').toUpperCase() === (userIdRef.current || '').toUpperCase();
            decryptMessage(keysRef.current.privateKey, encryptedContent, isMe).then(txt => {
              setDecryptedMessages(p => ({ ...p, [messageId]: txt }));
            }).catch(() => { });
          }
          return { ...prev, messages: newMsgs };
        }
        return prev;
      });
    });

    channel.join()
      .receive("ok", () => {
        console.log(`[Phoenix] Joined ${topic}`);
        if (onJoined) onJoined(channel);
      })
      .receive("error", () => console.error(`[Phoenix] Failed to join ${topic}`));

    setChatChannels(prev => {
      const next = new Map(prev);
      next.set(chatId, channel);
      return next;
    });
    return channel;
  };


  const handleSocketMessage = (data: any) => {
    // Use refs to get current values (avoid stale closures)
    const currentUserId = userIdRef.current;
    const currentSocket = socketRef.current;
    const currentKeys = keysRef.current;

    // Check if it is an ACK
    if (data.type === 'ack_delivery') {
      const { messageId, chatId } = data;
      // Update message status to 'delivered'
      setChats(prev => prev.map(c => {
        if (c.chatId === chatId) {
          return {
            ...c,
            messages: c.messages.map(m => m.id === messageId ? { ...m, status: 'delivered' } : m)
          };
        }
        return c;
      }));
      if (activeChatRef.current?.chatId === chatId) {
        setActiveChat(prev => prev ? {
          ...prev,
          messages: prev.messages.map(m => m.id === messageId ? { ...m, status: 'delivered' } : m)
        } : null);
      }
      return;
    }

    // Deobfuscate the payload - the result IS the message (flat structure)
    // { chatId, id, fromId, encryptedContent, type, timestamp, ... }
    const deobfuscated = data.d ? deobfuscatePayload(data) : data;
    const chatId = deobfuscated?.chatId;

    // The deobfuscated payload is the message itself (not nested inside a 'message' property)
    const message = deobfuscated && deobfuscated.id ? {
      id: deobfuscated.id,
      fromId: deobfuscated.fromId,
      encryptedContent: deobfuscated.encryptedContent,
      type: deobfuscated.type || 'text',
      timestamp: deobfuscated.timestamp || Date.now(),
      status: 'delivered' as const,
      replyToId: deobfuscated.replyToId,
      mediaUrl: deobfuscated.mediaUrl,
      plaintext: deobfuscated._senderPlaintext || deobfuscated.plaintext
    } : null;

    console.log('[Socket] Received message event:', { chatId, msgId: message?.id, from: message?.fromId, hasContent: !!message?.encryptedContent });

    if (!message || !message.id) return;

    // Check for duplicate message first (before any state updates)
    const isDuplicate = (chats: Chat[]) => {
      const chat = chats.find(c => c.chatId === chatId);
      return chat?.messages.some(m => m.id === message.id);
    };

    setChats(prev => {
      if (isDuplicate(prev)) return prev; // Skip if duplicate

      const chatExists = prev.some(c => c.chatId === chatId);
      if (chatExists) {
        const newChats = prev.map(c => {
          if (c.chatId === chatId) {
            if (c.messages.some(m => m.id === message.id)) return c;

            // Send ACK back (use refs for current values)
            const isMsgFromMe = (message.fromId || '').toUpperCase() === (currentUserId || '').toUpperCase();
            if (!isMsgFromMe) {
              Haptics.soft();
              // Also notify server for persistence (Fixes status revert on reload)
              chatChannelsRef.current.get(chatId)?.push('delivery-receipt', {
                chatId,
                messageId: message.id,
                deliveredToId: currentUserId
              });
            }

            return {
              ...c,
              messages: [...c.messages, { ...message }],
              unreadCount: (activeChatRef.current?.chatId !== chatId) ? (c.unreadCount || 0) + 1 : 0
            };
          }
          return c;
        });
        return newChats.sort((a, b) => {
          if (a.pinned && !b.pinned) return -1;
          if (!a.pinned && b.pinned) return 1;
          const tA = a.messages[a.messages.length - 1]?.timestamp || 0;
          const tB = b.messages[b.messages.length - 1]?.timestamp || 0;
          return tB - tA;
        });
      } else {
        // Chat not synchronized (new or race condition) - reload to ensure consistency
        console.log('[Socket] Chat not found/synced, reloading...');
        if (currentUserId) loadChats(currentUserId);

        const isMe = (message.fromId || '').toUpperCase() === (currentUserId || '').toUpperCase();
        if (!isMe) {
          // Check if we already have a chat with this friendId (to prevent duplicates)
          if (prev.some(c => c.friendId === message.fromId)) return prev;

          // Notify server of delivery for new chat messages too
          // Must join channel first if not joined
          if (currentSocket && !chatChannelsRef.current.has(chatId)) {
            joinChatChannel(chatId, currentSocket);
          }
          chatChannelsRef.current.get(chatId)?.push('delivery-receipt', {
            chatId,
            messageId: message.id,
            deliveredToId: currentUserId
          });

          const newChat: Chat = {
            chatId,
            friendId: message.fromId,
            friendName: `User ${message.fromId.slice(0, 5)}...`,
            messages: [message],
            unreadCount: 1,
            pinned: false,
            muted: false
          };

          // IMMEDIATE UPDATE: Add to list now
          const updated = [...prev, newChat].sort((a, b) => {
            const tA = a.messages[a.messages.length - 1]?.timestamp || 0;
            const tB = b.messages[b.messages.length - 1]?.timestamp || 0;
            return tB - tA;
          });

          // Trigger background refresh to get full user details
          // But don't block the UI update!
          setTimeout(() => {
            if (currentUserId) loadChats(currentUserId);
          }, 1000);

          return updated;
        }
      }
      return prev;
    });

    setActiveChat(prev => {
      if (prev && prev.chatId === chatId) {
        if (prev.messages.some(m => m.id === message.id)) return prev;
        return {
          ...prev,
          messages: [...prev.messages, { ...message }]
        };
      }
      return prev;
    });

    const isMe = (message.fromId || '').toUpperCase() === (currentUserId || '').toUpperCase();
    // Respect privacy setting - don't send read receipts if disabled
    if (activeChatRef.current?.chatId === chatId && currentSocket?.isConnected() && document.visibilityState === 'visible' && privacySettings.canSendReadReceipts()) {
      chatChannelsRef.current.get(chatId)?.push('read-receipt', { chatId, messageId: message.id, readerId: userId });
    }

    // First, check if plaintext is already available (e.g., from sender or P2P with plaintext)
    // plaintext is already consolidated during message construction above
    const existingPlaintext = message.plaintext;
    if (existingPlaintext && typeof existingPlaintext === 'string' && !existingPlaintext.startsWith('{')) {
      setDecryptedMessages(prev => ({ ...prev, [message.id]: existingPlaintext }));
      return; // No need to decrypt
    }

    // Only try to decrypt if we have keys and encrypted content
    if (currentKeys?.privateKey && message.encryptedContent && typeof message.encryptedContent === 'string') {
      decryptMessage(currentKeys.privateKey, message.encryptedContent, isMe)
        .then(async txt => {
          setDecryptedMessages(prev => ({ ...prev, [message.id]: txt }));
          if (message.type === 'image' || message.type === 'voice') {
            try {
              const { key, iv } = JSON.parse(txt);
              const aesKey = await importAESKey(key);
              const res = await fetch(message.mediaUrl!, { headers: { 'ngrok-skip-browser-warning': 'true' } });
              const encBlob = await res.arrayBuffer();
              const decBuffer = await decryptFile(aesKey, encBlob, new Uint8Array(iv));
              const blob = new Blob([decBuffer], { type: message.type === 'image' ? 'image/jpeg' : 'audio/webm' });
              const url = URL.createObjectURL(blob);
              setDecryptedMedia(prev => ({ ...prev, [message.id]: url }));
            } catch (e) { }
          }
        }).catch((err) => {
          console.error(`[Decrypt] Failed for incoming message ${message.id}:`, err.message);
          setDecryptedMessages(prev => ({ ...prev, [message.id]: 'Unable to decrypt' }));
          if ((err as any).code === 'KEY_MISMATCH') {
            setHasUndecryptableMessages(true);
          }
        });
    }
  };

  useEffect(() => {
    if (textareaRef.current) {
      textareaRef.current.style.height = 'auto';
      textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 120) + 'px';
    }
  }, [message]);







  useEffect(() => {
    const setHeight = () => {
      document.documentElement.style.setProperty('--app-height', `${window.innerHeight}px`);
    };
    setHeight();
    window.addEventListener('resize', setHeight);
    return () => window.removeEventListener('resize', setHeight);
  }, []);

  /* -- INITIALIZATION -- */
  useEffect(() => {
    const init = async () => {
      const { session, cachedChats } = await loadSession();
      const manager = ConnectionManager.getInstance();

      if (session) {
        setLoginToken(session.loginToken || null);
        setUserId(session.userId);
        setUsername(session.username);
        manager.setToken(session.loginToken);
      }

      const s = await manager.connect();

      manager.subscribe((status, _latency, endpoint) => {
        setConnectionStatus(status as any);

        const currentSocket = manager.getSocket();
        if (currentSocket) {
          setSocket(currentSocket);
        }

        if (endpoint) {
          setCurrentServerName(endpoint.name);
        }

        // Re-join logic on reconnect
        if (status === 'connected' && session?.userId && currentSocket && currentSocket.isConnected()) {
          joinUserChannel(session.userId, currentSocket);
          // Also re-join all active chat channels if we have them in state? 
          // Ideally loadChats will do it, or we rely on chatChannels state?
          // But chatChannels state map contains old channels from previous socket! We need to clear them or re-instantiate.
          // Best to just clear and let them re-join via loadChats or openChat
          setChatChannels(new Map());
          loadChats(session.userId);
          if (activeChat) {
            // Re-join active chat
            joinChatChannel(activeChat.chatId, currentSocket);
          }
        }
      });

      setSocket(s);

      if (session) {
        try {
          if (cachedChats && cachedChats.length > 0) {
            setChats(cachedChats);
            setAreChatsLoading(false);
          }

          const loadedKeys = importKeyPair(session); // Note: importKeyPair might be async or sync depending on implementation. Original code: await importKeyPair(session)
          setKeys(await loadedKeys);

          if (s && s.isConnected()) {
            joinUserChannel(session.userId, s);
            loadChats(session.userId);
          } else {
            // If socket is not ready yet, we can try to proceed with chats view anyway
            // The ConnectionManager connection flow will eventually connect the socket
            // and trigger re-joins, or we should wait? 
            // Ideally we proceed so user sees UI.
            loadChats(session.userId);
          }

          P2PManager.getInstance().init(session.userId?.toUpperCase());

          // Refresh from server
          setView('chats');

          if ('Notification' in window && Notification.permission === 'granted') {
            registerPush(session.userId);
          }
        } catch (e) {
          console.error('Session init error', e);
        }
      } else {
        setView('auth');
      }
    };
    init();
  }, []);



  // -- Helper Methods --

  const loadChats = async (uid: string) => {
    // Only show loading if we don't have any chats yet (prevents flashing)
    if (chats.length === 0) setAreChatsLoading(true);

    const manager = ConnectionManager.getInstance();
    const socket = manager.getSocket(); // Get socket for joining channels

    for (let i = 0; i < 2; i++) {
      try {
        try {
          const url = manager.getServerUrl();
          // Append userId to query to be safe
          const res = await fetch(`${url}/api/chats/${uid}?userId=${uid}`, {
            headers: { 'ngrok-skip-browser-warning': 'true' }
          });

          if (!res.ok) {
            console.warn(`[API] Failed to fetch chats (Attempt ${i + 1}): ${res.status}`);
            if (i === 1) break; // Stop after retries
            await new Promise(r => setTimeout(r, 1000));
            continue;
          }

          const data = await res.json();

          // Automatically join channels for all loaded chats
          if (socket && socket.isConnected()) {
            data.forEach((c: any) => {
              joinChatChannel(c.chatId, socket);
            });
          }

          const sorted = data.map((c: any) => ({
            ...c,
            messages: (c.messages || (c.lastMessage ? [c.lastMessage] : [])).map((rawM: any) => {
              const m = normalizeMessage(rawM);

              const isMe = (m.fromId || '').toUpperCase() === (uid || '').toUpperCase();
              if (isMe && m.readBy && c.friendId && m.readBy.includes(c.friendId)) {
                return { ...m, status: 'read' as const };
              }
              return m;
            })
          })).sort((a: Chat, b: Chat) => {
            // Sort by pinned, then time
            if (a.pinned && !b.pinned) return -1;
            if (!a.pinned && b.pinned) return 1;

            const tA = a.messages[a.messages.length - 1]?.timestamp || 0;
            const tB = b.messages[b.messages.length - 1]?.timestamp || 0;
            return tB - tA;
          });

          // Merge with previous state to preserve plaintext
          setChats(prev => {
            const plaintextMap = new Map<string, string>();
            prev.forEach(c => {
              c.messages.forEach(m => {
                if (m.plaintext) plaintextMap.set(m.id, m.plaintext);
              });
            });

            const finalChats = sorted.map((c: Chat) => {
              const prevChat = prev.find(p => p.chatId === c.chatId);
              // If we have existing messages, prefer them but add any new ones from API (like lastMessage)
              let mergedMessages = c.messages;

              if (prevChat && prevChat.messages && prevChat.messages.length > 0) {
                const newMsgIds = new Set(c.messages.map((m: any) => m.id));
                // Keep old messages that aren't in the new list (which is usually just the last summary message)
                const oldMessages = prevChat.messages.filter(m => !newMsgIds.has(m.id));
                mergedMessages = [...oldMessages, ...c.messages].sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));

                console.log(`[loadChats] Merged ${c.chatId}:`, {
                  old: oldMessages.length,
                  new: c.messages.length,
                  total: mergedMessages.length,
                  timestamps: mergedMessages.map(m => new Date(m.timestamp).toLocaleTimeString())
                });
              }

              return {
                ...c,
                messages: mergedMessages.map((m: any) => {
                  const existingText = plaintextMap.get(m.id);
                  return {
                    ...m,
                    plaintext: existingText || m.plaintext || m._senderPlaintext
                  };
                })
              };
            });

            saveChatsToLocalStorage(finalChats, uid);
            return finalChats;
          });

          break;
        } catch (innerErr) {
          // Inner fetch failed, let outer loop handle it
          throw innerErr;
        }
      } catch (e) {
        console.error('Load Error:', e);
        if (i === 0) {
          await manager.handleConnectionFailure();
          await manager.findWorkingEndpoint();
        }
      }
    }
    setAreChatsLoading(false);
  };

  const handleRefresh = async () => {
    if (!userId) return;
    setIsRefreshing(true);
    try {
      const res = await fetch(`${getApiUrl()}/api/chats/${userId}`, {
        headers: { 'ngrok-skip-browser-warning': 'true' }
      });
      const data = await res.json();

      setChats(prev => {
        const existingMap = new Map(prev.map(c => [c.chatId, c]));

        const merged = data.map((serverChat: any) => {
          const existing = existingMap.get(serverChat.chatId);

          // 1. Prepare & Sanitize Server Messages (Summary)
          const rawServerMsgs = serverChat.messages || (serverChat.lastMessage ? [serverChat.lastMessage] : []);

          const serverMsgs = rawServerMsgs.map((rawM: any) => {
            const m = normalizeMessage(rawM);

            // Allow preserving local plaintext if available (crucial for own messages)
            if (!m.plaintext && existing) {
              const local = existing.messages.find(lm => lm.id === m.id);
              if (local && local.plaintext) m.plaintext = local.plaintext;
            }

            const isMe = (m.fromId || '').toUpperCase() === (userId || '').toUpperCase();
            if (isMe && m.readBy && serverChat.friendId && m.readBy.includes(serverChat.friendId)) {
              return { ...m, status: 'read' };
            }
            return m;
          });

          // 2. Merge Strategies
          if (existing && existing.messages.length > 1) {
            // We have full history. Keep it, but update the HEAD if needed.
            let updatedMessages = existing.messages;
            const serverLast = serverMsgs[serverMsgs.length - 1];

            if (serverLast) {
              const localLast = existing.messages[existing.messages.length - 1];
              // If last message matches but local is stale (e.g. missed socket event for read receipt)
              if (localLast && localLast.id === serverLast.id) {
                if (serverLast.status === 'read' && localLast.status !== 'read') {
                  updatedMessages = [...existing.messages];
                  updatedMessages[updatedMessages.length - 1] = {
                    ...localLast,
                    status: 'read',
                    readBy: serverLast.readBy
                  };
                }
              } else if (localLast && serverLast.timestamp > localLast.timestamp) {
                // Optimization: If server has a NEWER message, we might want to append it?
                // Typically handleRefresh is just a summary, so appending a single message is safeish if sequential.
                // But safer to just let the user 'openChat' to fetch full history if gap is large.
                // For now, we only update status of EXISTING head.
              }
            }
            return { ...existing, ...serverChat, messages: updatedMessages };
          }

          // No local history (or just preview), use server summary
          if (existing) {
            return { ...existing, ...serverChat, messages: serverMsgs };
          }
          return { ...serverChat, messages: serverMsgs };
        });

        const sorted = merged.sort((a: Chat, b: Chat) => {
          if (a.pinned && !b.pinned) return -1;
          if (!a.pinned && b.pinned) return 1;

          const tA = a.messages[a.messages.length - 1]?.timestamp || 0;
          const tB = b.messages[b.messages.length - 1]?.timestamp || 0;
          return tB - tA;
        });

        // Preserve local pending chats that are NOT in the server response
        // This prevents flickering/deletion of chats just created but not yet synced fully
        const pendingChats = prev.filter(c => c.chatId.startsWith('pending_') && !data.some((d: any) => d.friendId === c.friendId));
        return [...sorted, ...pendingChats];
      });

      // SYNC ACTIVE CHAT KEYS
      if (activeChat) {
        const serverVersion = data.find((c: any) => c.chatId === activeChat.chatId);
        if (serverVersion) {
          let newKey = activeChat.friendKey;
          if (serverVersion.friendKey) {
            try {
              if (typeof serverVersion.friendKey === 'string') {
                newKey = await importPublicKey(serverVersion.friendKey);
              }
            } catch (err) {
              console.error("Failed to update active chat key", err);
            }
          }

          setActiveChat(prev => {
            if (!prev) return null;
            return {
              ...prev,
              ...serverVersion,
              friendKey: newKey,
              messages: prev.messages
            };
          });
        }
      }
      setToast('Chat list updated');
      setTimeout(() => setToast(null), 2000);
    } catch (e) {
      setToast('Update failed');
      setTimeout(() => setToast(null), 2000);
    } finally {
      setIsRefreshing(false);
      setAreChatsLoading(false);
    }
  };

  const openChat = async (chat: Chat) => {
    console.log('[Chat] openChat called for:', chat.chatId);

    // Get the most up-to-date version of this chat from chats state
    const cachedChat = chats.find(c => c.chatId === chat.chatId) || chat;

    // 1. OPTIMISTIC NAVIGATION: Go immediately with cached data
    setChats(prev => prev.map(c => c.chatId === chat.chatId ? { ...c, unreadCount: 0 } : c));

    // Set active chat using cached data (preserves messages + status)
    setActiveChat(cachedChat);
    setView('chat');

    // 2. Check if we need to fetch messages (only if we have very few or none)
    const hasEnoughMessages = cachedChat.messages && cachedChat.messages.length > 1;

    // 3. BACKGROUND: Fetch key and optionally messages
    try {
      let fKey = cachedChat.friendKey;

      // Fetch fresh public key
      try {
        const res = await fetch(`${getApiUrl()}/api/user/${chat.friendId}`, {
          headers: { 'ngrok-skip-browser-warning': 'true' }
        });
        if (res.ok) {
          const d = await res.json();
          fKey = await importPublicKey(d.publicKey);

          // SYNC ONLINE STATUS: API returns true/false for online
          if (typeof d.online === 'boolean') {
            const fid = chat.friendId.toUpperCase();
            setOnlineUsers(prev => {
              const next = new Set(prev);
              if (d.online) next.add(fid);
              else next.delete(fid);
              return next;
            });
          }
        }
      } catch (keyErr) {
        console.warn('[KEYS] Failed to fetch fresh key, using cached:', keyErr);
      }

      // Only fetch messages if we don't have enough cached and NOT pending
      if (!hasEnoughMessages && !chat.chatId.startsWith('pending_')) {
        const mRes = await fetch(`${getApiUrl()}/api/chat/${chat.chatId}/messages?limit=30`, {
          headers: { 'ngrok-skip-browser-warning': 'true' }
        });

        let msgs: Message[] = [];
        if (mRes.ok) {
          const msgsRaw = await mRes.json();
          const msgItems = Array.isArray(msgsRaw)
            ? msgsRaw
            : Array.isArray(msgsRaw?.messages)
              ? msgsRaw.messages
              : Array.isArray(msgsRaw?.data)
                ? msgsRaw.data
                : [];
          msgs = msgItems.map((m: any) => ({
            ...m,
            plaintext: m._senderPlaintext || m.senderPlaintext || m.sender_plaintext || m.plaintext
          }));
        }

        // Mark Read on Server
        if (privacySettings.canSendReadReceipts()) {
          const chatChannel = chatChannelsRef.current.get(chat.chatId);
          msgs.forEach((m: Message) => {
            const isFromMe = (m.fromId || '').toUpperCase() === (userId || '').toUpperCase();
            if (!isFromMe && (!m.readBy || !m.readBy.includes(userId!))) {
              chatChannel?.push('read-receipt', { chatId: chat.chatId, messageId: m.id, readerId: userId });
            }
          });
        }

        // Merge server messages with local to preserve status
        setActiveChat(prev => {
          if (prev && prev.chatId === chat.chatId) {
            const localMsgMap = new Map(prev.messages.map(m => [m.id, m]));
            const mergedMsgs = msgs.map(serverMsg => {
              const localMsg = localMsgMap.get(serverMsg.id);
              if (localMsg) {
                // Keep local status if better
                const statusPriority: Record<string, number> = { 'sending': 0, 'sent': 1, 'delivered': 2, 'read': 3, 'error': -1 };
                const localPriority = statusPriority[localMsg.status || 'sending'] || 0;
                const serverPriority = statusPriority[serverMsg.status || 'sending'] || 0;
                return {
                  ...serverMsg,
                  status: localPriority >= serverPriority ? localMsg.status : serverMsg.status,
                  plaintext: localMsg.plaintext || serverMsg.plaintext
                };
              }
              return serverMsg;
            });
            return { ...prev, friendKey: fKey, messages: mergedMsgs };
          }
          return prev;
        });

        // Update chats list
        setChats(prev => prev.map(c => c.chatId === chat.chatId ? { ...c, friendKey: fKey, messages: msgs } : c));

        // Decrypt new messages
        if (keys?.privateKey) {
          msgs.forEach((m: Message) => decryptMsgIfNeeded(m, keys.privateKey!));
        }
      } else {
        // Just update key
        setActiveChat(prev => prev && prev.chatId === chat.chatId ? { ...prev, friendKey: fKey } : prev);

        // Mark unread as read
        if (privacySettings.canSendReadReceipts()) {
          const chatChannel = chatChannelsRef.current.get(chat.chatId);
          cachedChat.messages.forEach((m: Message) => {
            const isFromMe = (m.fromId || '').toUpperCase() === (userId || '').toUpperCase();
            if (!isFromMe && (!m.readBy || !m.readBy.includes(userId!))) {
              chatChannel?.push('read-receipt', { chatId: chat.chatId, messageId: m.id, readerId: userId });
            }
          });
        }

        // Decrypt cached messages if needed
        if (keys?.privateKey) {
          cachedChat.messages.forEach((m: Message) => decryptMsgIfNeeded(m, keys.privateKey!));
        }
      }
    } catch (e) {
      console.error("Background chat load failed", e);
    }
  };

  // Helper to decrypt a message if not already decrypted
  const decryptMsgIfNeeded = (m: Message, privateKey: CryptoKey) => {
    const isFromMe = (m.fromId || '').toUpperCase() === (userId || '').toUpperCase();
    if (decryptedMessages[m.id]) return;

    const plaintext = m.plaintext || (m as any).senderPlaintext || (m as any).sender_plaintext || (m as any)._senderPlaintext;
    if (plaintext && typeof plaintext === 'string' && plaintext.length > 0 && !plaintext.startsWith('{')) {
      setDecryptedMessages(prev => ({ ...prev, [m.id]: plaintext }));
      return;
    }

    if (m.encryptedContent) {
      decryptMessage(privateKey, m.encryptedContent, isFromMe)
        .then(async txt => {
          setDecryptedMessages(prev => ({ ...prev, [m.id]: txt }));
          if ((m.type === 'image' || m.type === 'voice') && m.mediaUrl && !decryptedMedia[m.id]) {
            try {
              const { key, iv } = JSON.parse(txt);
              const aesKey = await importAESKey(key);
              const res = await fetch(m.mediaUrl, { headers: { 'ngrok-skip-browser-warning': 'true' } });
              if (res.ok) {
                const encBlob = await res.arrayBuffer();
                const decBuffer = await decryptFile(aesKey, encBlob, new Uint8Array(iv));
                const blob = new Blob([decBuffer], { type: m.type === 'image' ? 'image/jpeg' : 'audio/webm' });
                setDecryptedMedia(prev => ({ ...prev, [m.id]: URL.createObjectURL(blob) }));
              }
            } catch (e) { console.error('Media Decryption Error:', e); }
          }
        })
        .catch(() => setDecryptedMessages(prev => ({ ...prev, [m.id]: 'Decryption Failed' })));
    }

    if ((m as any).extra && !decryptedMessages[`caption-${m.timestamp}`]) {
      decryptMessage(privateKey, (m as any).extra, isFromMe)
        .then(t => setDecryptedMessages(prev => ({ ...prev, [`caption-${m.timestamp}`]: t })))
        .catch(() => { });
    }
  };

  const deleteChat = async (chatId: string) => {
    if (!confirm('Delete this chat?')) return;
    try {
      if (activeChat?.chatId === chatId) {
        setView('chats');
        setActiveChat(null);
      }
      setChats(prev => prev.filter(c => c.chatId !== chatId));
      await fetch(`${getApiUrl()}/api/chats/${chatId}`, {
        method: 'DELETE',
        headers: {
          'Content-Type': 'application/json',
          'ngrok-skip-browser-warning': 'true',
          'Authorization': `Bearer ${userId}`
        },
        body: JSON.stringify({ userId })
      });
    } catch (e) { console.error(e); }
  };

  const pinChat = async (chatId: string) => {
    // Find current pin status
    const chat = chats.find(c => c.chatId === chatId);
    if (!chat) return;

    const newPinned = !chat.pinned;

    // Optimistic update
    setChats(prev => {
      const updated = prev.map(x => x.chatId === chatId ? { ...x, pinned: newPinned } : x);
      return updated.sort((a, b) => {
        if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
        const tA = a.messages[a.messages.length - 1]?.timestamp || 0;
        const tB = b.messages[b.messages.length - 1]?.timestamp || 0;
        return tB - tA;
      });
    });

    setToast(newPinned ? 'Chat pinned' : 'Chat unpinned');
    setTimeout(() => setToast(null), 2000);

    // Persist to backend
    try {
      await fetch(`${getApiUrl()}/api/chat/${chatId}/pin`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
        body: JSON.stringify({ userId, pinned: newPinned })
      });
    } catch (e) {
      console.error('Failed to persist pin:', e);
    }
  };

  // Helper to bridge for ChatList which passes ID


  const clearChat = async (chatId: string) => {
    if (!confirm('Clear all messages in this chat?')) return;

    // Optimistic
    setChats(prev => prev.map(c => c.chatId === chatId ? { ...c, messages: [] } : c));
    if (activeChat && activeChat.chatId === chatId) {
      setActiveChat(prev => prev ? ({ ...prev, messages: [] }) : null);
    }
    setDecryptedMessages(prev => {
      // Simple way: clear all for now, or sophisticated filtered clear. 
      // For simplicity, we just won't show anything.
      return prev;
    });

    // API Call
    try {
      const res = await fetch(`${getApiUrl()}/api/chat/${chatId}/messages?userId=${userId}`, {
        method: 'DELETE',
        headers: { 'ngrok-skip-browser-warning': 'true' }
      });
      if (!res.ok) throw new Error('Server error');
      setToast('Chat history cleared');
      setTimeout(() => setToast(null), 3000);
    } catch (e) {
      console.error("Failed to clear history", e);
      alert("Failed to clear history");
    }
  };

  // Track decryption in progress to prevent duplicate calls
  const decryptingRef = useRef<Set<string>>(new Set());

  const getMsgText = (m: Message) => {
    // 1. Decrypted cache (for both me and them)
    if (decryptedMessages[m.id]) return decryptedMessages[m.id];

    // 2. Plaintext from message (for sender's messages - stored when sending or from server)
    const plaintext = m.plaintext || (m as any).senderPlaintext || (m as any).sender_plaintext || (m as any)._senderPlaintext;
    if (plaintext && typeof plaintext === 'string' && plaintext.length > 0 && !plaintext.startsWith('{')) {
      return plaintext;
    }

    // 3. Try to decrypt if we have the keys and encrypted content
    const isFromMe = (m.fromId || '').toUpperCase() === (userId || '').toUpperCase();
    if (keys?.privateKey && m.encryptedContent && !decryptingRef.current.has(m.id)) {
      // Mark as decrypting to prevent duplicate calls
      decryptingRef.current.add(m.id);

      // Trigger async decryption
      decryptMessage(keys.privateKey, m.encryptedContent, isFromMe)
        .then(txt => {
          decryptingRef.current.delete(m.id);
          setDecryptedMessages(prev => ({ ...prev, [m.id]: txt }));
        })
        .catch((err) => {
          decryptingRef.current.delete(m.id);
          console.error(`[Decrypt] Failed for message ${m.id}:`, err.message);
          // Mark as failed so we don't keep retrying
          setDecryptedMessages(prev => ({ ...prev, [m.id]: 'Unable to decrypt' }));
          // Track that we have undecryptable messages (likely key mismatch)
          if ((err as any).code === 'KEY_MISMATCH') {
            setHasUndecryptableMessages(true);
          }
        });
    }

    // 4. Return loading indicator for non-text messages, or null for text
    if (m.type === 'text') {
      return null; // Show loading for text messages
    }
    return null;
  };

  const handleCopy = (m: Message) => {
    const txt = getMsgText(m);
    if (txt) { navigator.clipboard.writeText(txt); setToast('Copied'); setTimeout(() => setToast(null), 2000); }
  };

  const sendMessage = async () => {
    if ((!message.trim() && !selectedFile) || !activeChat || !userId || !keys) return;
    const textToSend = message.trim();
    const currentReplyingTo = replyingTo;
    const tempId = crypto.randomUUID();

    // Clear input IMMEDIATELY for responsive feel
    setMessage(''); setReplyingTo(null); setSelectedFile(null); setMediaPreview(null);

    if (selectedFile) {
      await sendMedia(selectedFile, textToSend);
      return;
    }

    // 1. INSTANT Optimistic UI - Show message before encryption
    const isConnected = socket?.isConnected();
    const newItem: Message = {
      id: tempId,
      fromId: userId,
      encryptedContent: '',
      type: 'text',
      timestamp: Date.now(),
      status: isConnected ? 'sending' : 'pending', // Correct status based on connection
      errorMessage: undefined,
      plaintext: textToSend
    };
    if (currentReplyingTo) newItem.replyToId = currentReplyingTo.id;

    // Show in UI immediately
    setActiveChat(prev => prev ? ({ ...prev, messages: [...prev.messages, newItem] }) : null);
    setDecryptedMessages(prev => ({ ...prev, [tempId]: textToSend }));

    // Update chat list immediately
    setChats(prev => {
      const chatExists = prev.some(c => c.chatId === activeChat.chatId);
      let newChats;
      if (chatExists) {
        newChats = prev.map(c => c.chatId === activeChat.chatId ? { ...c, messages: [...c.messages, newItem], lastMessage: newItem } : c);
      } else {
        newChats = [{ ...activeChat, messages: [newItem], lastMessage: newItem }, ...prev];
      }
      return newChats.sort((a, b) => {
        if (a.pinned !== b.pinned) return a.pinned ? -1 : 1;
        return (b.lastMessage?.timestamp || b.messages[b.messages.length - 1]?.timestamp || 0) - (a.lastMessage?.timestamp || a.messages[a.messages.length - 1]?.timestamp || 0);
      });
    });

    // If offline, just queue it (conceptually) - here we just leave it as 'pending' in state. 
    // The socket reset/reconnect logic should handle re-sending or user manually retries.
    // However, the `sendMessage` function continues to try background send. 
    // We should probably attempt it even if disconnected? No, it will fail.
    if (!isConnected) {
      console.log('[SEND] Offline, message marked as pending');
      return;
    }

    // 2. Background: Encrypt and send
    (async () => {
      try {
        let friendKey = activeChat.friendKey;

        if (!friendKey) {
          console.log(`[SEND] Fetching fresh public key for ${activeChat.friendId}...`);
          try {
            const controller = new AbortController();
            const cleanId = setTimeout(() => controller.abort(), 10000);
            const res = await fetch(`${getApiUrl()}/api/user/${activeChat.friendId}`, {
              headers: { 'ngrok-skip-browser-warning': 'true' },
              signal: controller.signal
            });
            clearTimeout(cleanId);

            if (res.ok) {
              const data = await res.json();
              friendKey = await importPublicKey(data.publicKey);
              // Cache it locally
              setActiveChat(prev => prev ? ({ ...prev, friendKey: friendKey }) : null);
              setChats(prev => prev.map(c => c.chatId === activeChat.chatId ? { ...c, friendKey: friendKey } : c));
            } else if (res.status === 404) {
              throw new Error('User no longer exists');
            } else {
              console.warn('[SEND] Failed to fetch key, status:', res.status);
            }
          } catch (err) {
            console.warn('[SEND] Key fetch failed:', err);
            if ((err as Error).message === 'User no longer exists') throw err;
          }
        } else {
          console.log('[SEND] Using cached public key');
        }

        // --- 1. HANDLE PENDING CHAT CREATION ---
        let currentChatId = activeChat.chatId;
        let finalFriendKey = friendKey;

        if (currentChatId.startsWith('pending_')) {

          try {
            console.log('[SEND] Creating real chat for pending:', currentChatId);
            const res = await fetch(`${getApiUrl()}/api/chat`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
              body: JSON.stringify({ myId: userId, friendId: activeChat.friendId })
            });

            if (!res.ok) throw new Error('Failed to create chat');
            const { chatId, } = await res.json();
            currentChatId = chatId;

            // Update local state immediately - REPLACE pending with real, verifying we preserve messages
            setActiveChat(prev => prev ? ({ ...prev, chatId: currentChatId }) : null);

            setChats(prev => {
              // Check if duplicate exists (race condition)
              if (prev.some(c => c.chatId === currentChatId)) {
                return prev.filter(c => c.chatId !== activeChat.chatId);
              }
              // Otherwise replace pending with real, preserving messages
              return prev.map(c => c.chatId === activeChat.chatId ? { ...c, chatId: currentChatId } : c);
            });

            // Ensure we have a channel joined
            const manager = ConnectionManager.getInstance();
            const skt = manager.getSocket();
            if (skt && skt.isConnected()) {
              await new Promise<void>(resolve => {
                joinChatChannel(currentChatId, skt, () => resolve());
              });
            }
          } catch (e) {
            console.error('Failed to create pending chat:', e);
            setToast('Failed to start conversation');
            return;
          }
        }

        // --- 2. ENCRYPTION ---
        // Verify key again just in case
        if (!finalFriendKey) {
          // Try one last fetch if missing
          // ...
        }


        if (!friendKey || !(friendKey instanceof CryptoKey)) {
          throw new Error('Encryption key unavailable');
        }

        // Encrypt (CPU bound, usually fast <10ms for short text)
        const encryptedContent = await encryptMessage(friendKey, textToSend, keys?.publicKey);

        // Update message with encrypted content, keep status as 'sending'
        setActiveChat(prev => prev ? ({
          ...prev,
          messages: prev.messages.map(m => m.id === tempId ? { ...m, encryptedContent } : m)
        }) : null);

        // Send via socket
        const manager = ConnectionManager.getInstance();
        const currentSocket = manager.getSocket();

        const socketPayload = obfuscatePayload({
          chatId: currentChatId,
          encryptedContent,
          type: 'text',
          fromId: userId,
          id: tempId,
          replyToId: currentReplyingTo?.id
        });



        if (currentSocket?.isConnected()) {
          // OPTIMISTICALLY set to 'sent' immediately if socket is connected.
          setActiveChat(prev => prev ? ({
            ...prev,
            chatId: currentChatId, // Ensure ID is correct
            messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'sent' } : m)
          }) : null);

          setChats(prev => prev.map(c => c.chatId === currentChatId ? {
            ...c,
            messages: c.messages.map(m => m.id === tempId ? { ...m, status: 'sent' } : m)
          } : c));

          // Find the channel
          // Use 'currentChatId' here!
          let channel: Channel | null | undefined = chatChannelsRef.current.get(currentChatId);
          console.log(`[SEND] Sending message ${tempId} to chat ${currentChatId}`, { payload: socketPayload, channelExists: !!channel });

          if (!channel) {
            // If missing (rare race condition if join above failed), try strict join
            if (currentSocket) {
              channel = joinChatChannel(currentChatId, currentSocket);
            }
          }

          if (channel) {
            channel.push('message', socketPayload)
              .receive("ok", (resp) => {
                console.log(`[SEND] Success for ${tempId}`, resp);
              })
              .receive("error", (resp) => {
                console.error('[Socket] Send error:', resp);
                setActiveChat(prev => prev ? ({
                  ...prev,
                  messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
                }) : null);
              });
          } else {
            console.warn(`[SEND] Channel for chat ${activeChat.chatId} not found, joining now...`);
            // Join the channel first, then send after join succeeds via callback
            joinChatChannel(activeChat.chatId, currentSocket, (joinedChannel) => {
              console.log(`[SEND] Joined channel callback, now sending message ${tempId}`);
              joinedChannel.push('message', socketPayload)
                .receive("ok", (resp: any) => {
                  console.log(`[SEND] Success for ${tempId}`, resp);
                })
                .receive("error", (resp: any) => {
                  console.error('[Socket] Send error after join:', resp);
                  setActiveChat(prev => prev ? ({
                    ...prev,
                    messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
                  }) : null);
                });
            });
          }
          // P2P logic is already handled above

        } else {
          console.warn('[SEND] Socket not connected during send attempt');
          // Queue retry
          manager.forceReconnect();
          setTimeout(() => {
            const retrySocket = ConnectionManager.getInstance().getSocket();
            if (retrySocket?.isConnected()) {
              const ch = chatChannelsRef.current.get(activeChat.chatId);
              ch?.push('message', socketPayload);
            } else {
              setActiveChat(prev => prev ? ({
                ...prev,
                messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
              }) : null);
              setToast('No connection');
              setTimeout(() => setToast(null), 3000);
            }
          }, 2000);
        }
      } catch (err: any) {
        console.error('[Send] Error:', err);
        setActiveChat(prev => prev ? ({
          ...prev,
          messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
        }) : null);
        setToast(err.message || 'Failed to send');
        setTimeout(() => setToast(null), 3000);
      }
    })();
  };

  const sendMedia = async (file: File, caption: string) => {
    if (!activeChat || !userId || !keys) return;
    const tempId = crypto.randomUUID();
    const type = file.type.startsWith('audio') ? 'voice' : 'image';

    const optimisticMsg: Message = {
      id: tempId, fromId: userId, encryptedContent: '...', type, timestamp: Date.now(), status: 'sending', mediaUrl: URL.createObjectURL(file)
    };

    setActiveChat(prev => prev ? ({ ...prev, messages: [...prev.messages, optimisticMsg] }) : null);
    setDecryptedMedia(prev => ({ ...prev, [tempId]: optimisticMsg.mediaUrl! }));

    try {
      // Validate friendKey - if missing or invalid, try to fetch it
      let friendKey = activeChat.friendKey;
      if (!friendKey || !(friendKey instanceof CryptoKey)) {
        console.warn("[sendMedia] Friend key missing or invalid, attempting to fetch...");
        try {
          const res = await fetch(`${getApiUrl()}/api/user/${activeChat.friendId}`, {
            headers: { 'ngrok-skip-browser-warning': 'true' }
          });
          if (res.ok) {
            const userData = await res.json();
            if (userData.publicKey) {
              friendKey = await importPublicKey(userData.publicKey);
              // Update activeChat with the valid key for future use
              setActiveChat(prev => prev ? { ...prev, friendKey } : null);
            }
          }
        } catch (e) {
          console.error('Failed to fetch friend key:', e);
        }
      }

      if (!friendKey || !(friendKey instanceof CryptoKey)) {
        throw new Error("Encryption key unavailable. Cannot send message.");
      }

      // Upload
      const formData = new FormData();
      // Encrypt File
      const aesKey = await generateAESKey();
      const fileBuffer = await file.arrayBuffer();
      // FIX: encryptFile returns { encrypted, iv } based on crypto.ts
      const { encrypted: encryptedFile, iv } = await encryptFile(aesKey, fileBuffer);

      const blob = new Blob([encryptedFile]);
      formData.append('file', blob);

      const res = await fetch(`${getApiUrl()}/api/upload`, {
        method: 'POST',
        headers: { 'ngrok-skip-browser-warning': 'true' },
        body: formData
      });
      const { url } = await res.json();

      // Encrypt Key+IV with friend's public key AND my public key (Self-Decryption)
      const keyExport = await exportAESKey(aesKey);
      const meta = JSON.stringify({ key: keyExport, iv: Array.from(iv) });
      const encryptedMeta = await encryptMessage(friendKey, meta, keys.publicKey);

      console.log('Sending media payload:', { activeChatId: activeChat.chatId, fromId: userId, mediaUrl: url });

      let encryptedCaption = '';
      if (caption) {
        encryptedCaption = await encryptMessage(friendKey, caption, keys.publicKey);
      }

      const payload = obfuscatePayload({
        chatId: activeChat.chatId,
        id: tempId,
        fromId: userId,
        encryptedContent: encryptedMeta,
        type,
        timestamp: optimisticMsg.timestamp,
        mediaUrl: url,
        extra: encryptedCaption
      });

      const manager = ConnectionManager.getInstance();
      const currentSocket = manager.getSocket();

      if (currentSocket?.isConnected()) {
        const channel = chatChannelsRef.current.get(activeChat.chatId);
        if (channel) {
          channel.push('message', payload)
            .receive("ok", () => {
              setActiveChat(prev => prev ? ({
                ...prev,
                messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'sent' as const, mediaUrl: url } : m)
              }) : null);
            })
            .receive("error", (resp) => {
              console.error("Socket error on sendMedia:", resp);
              setActiveChat(prev => prev ? ({
                ...prev,
                messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
              }) : null);
            });
        }
      } else {
        throw new Error("Socket disconnected");
      }

    } catch (e) {
      console.error("sendMedia failed:", e);
      setToast('Failed to send media');
      setTimeout(() => setToast(null), 3000);
      setActiveChat(prev => prev ? ({
        ...prev,
        messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
      }) : null);
    }
  };

  const sendGif = async (gifUrl: string) => {
    if (!activeChat || !userId || !keys) return;

    try {
      const tempId = crypto.randomUUID();

      // Validate friendKey - if missing or invalid, try to fetch it
      let friendKey = activeChat.friendKey;
      if (!friendKey || !(friendKey instanceof CryptoKey)) {
        try {
          const res = await fetch(`${getApiUrl()}/api/user/${activeChat.friendId}`, {
            headers: { 'ngrok-skip-browser-warning': 'true' }
          });
          if (res.ok) {
            const userData = await res.json();
            friendKey = await importPublicKey(userData.publicKey);
            // Update activeChat with the valid key
            setActiveChat(prev => prev ? { ...prev, friendKey } : null);
          }
        } catch (e) {
          console.error('Failed to fetch friend key:', e);
        }
      }

      if (!friendKey || !(friendKey instanceof CryptoKey)) {
        setToast('Cannot send: Encryption key unavailable');
        setTimeout(() => setToast(null), 3000);
        return;
      }

      // Show optimistic message with loading state
      const optimisticMsg: Message = {
        id: tempId,
        fromId: userId,
        encryptedContent: '...',
        type: 'gif',
        timestamp: Date.now(),
        status: 'sending',
        mediaUrl: gifUrl
      };

      setActiveChat(prev => prev ? ({ ...prev, messages: [...prev.messages, optimisticMsg] }) : null);
      setToast('Encrypting GIF...');
      setTimeout(() => setToast(null), 2000);

      // Download the GIF
      const response = await fetch(gifUrl);
      const gifBlob = await response.blob();

      // Validate size (max 10MB)
      if (gifBlob.size > 10 * 1024 * 1024) {
        setToast('GIF too large (max 10MB)');
        setTimeout(() => setToast(null), 3000);
        setActiveChat(prev => prev ? ({
          ...prev,
          messages: prev.messages.filter(m => m.id !== tempId)
        }) : null);
        return;
      }

      // Encrypt the GIF
      const aesKey = await generateAESKey();
      const gifBuffer = await gifBlob.arrayBuffer();
      const { encrypted: encryptedGif, iv } = await encryptFile(aesKey, gifBuffer);

      // Upload encrypted GIF
      const formData = new FormData();
      formData.append('file', new Blob([encryptedGif]), 'encrypted.gif');

      const uploadRes = await fetch(`${getApiUrl()}/api/upload`, {
        method: 'POST',
        headers: { 'ngrok-skip-browser-warning': 'true' },
        body: formData
      });

      if (!uploadRes.ok) {
        throw new Error('Upload failed');
      }

      const { url } = await uploadRes.json();

      // Encrypt metadata (AES key + IV)
      const keyExport = await exportAESKey(aesKey);
      const meta = JSON.stringify({ key: keyExport, iv: Array.from(iv) });
      const encryptedMeta = await encryptMessage(friendKey, meta, keys.publicKey);

      // Send via socket
      const payload = obfuscatePayload({
        chatId: activeChat.chatId,
        id: tempId,
        fromId: userId,
        encryptedContent: encryptedMeta,
        type: 'gif',
        timestamp: optimisticMsg.timestamp,
        mediaUrl: url
      });

      const manager = ConnectionManager.getInstance();
      const currentSocket = manager.getSocket();

      if (currentSocket?.isConnected()) {
        const channel = chatChannelsRef.current.get(activeChat.chatId);
        if (!channel) {
          console.error("No channel for chat");
          return;
        }

        channel.push('message', payload)
          .receive("ok", () => {
            // Success
            setActiveChat(prev => prev ? ({
              ...prev,
              messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'sent' as const, mediaUrl: url } : m)
            }) : null);
          })
          .receive("error", (resp) => {
            console.error("Socket error on sendGif:", resp);
            setActiveChat(prev => prev ? ({
              ...prev,
              messages: prev.messages.map(m => m.id === tempId ? { ...m, status: 'error' } : m)
            }) : null);
          });
      } else {
        throw new Error("Socket disconnected");
      }

      // Store decrypted GIF for immediate display
      setDecryptedMedia(prev => ({ ...prev, [tempId]: gifUrl }));

    } catch (error) {
      console.error('Failed to send GIF:', error);
      setToast('Failed to send GIF');
      setTimeout(() => setToast(null), 3000);
    }
  };

  const startRecording = async () => {
    Haptics.medium();
    recordingStatusRef.current = 'starting';
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

      // Check if cancelled/stopped while waiting for permission/stream
      if ((recordingStatusRef.current as string) === 'cancelling' || (recordingStatusRef.current as string) === 'stopping') {
        stream.getTracks().forEach(t => t.stop());
        recordingStatusRef.current = 'idle';
        return;
      }

      const mediaRecorder = new MediaRecorder(stream);
      mediaRecorderRef.current = mediaRecorder;
      audioChunksRef.current = [];

      mediaRecorder.ondataavailable = (event) => {
        if (event.data.size > 0) audioChunksRef.current.push(event.data);
      };

      mediaRecorder.onstop = () => {
        const audioBlob = new Blob(audioChunksRef.current, { type: 'audio/webm' });
        // If file is empty, just return (avoid alert spam on quick taps)
        if (audioBlob.size === 0) return;
        const file = new File([audioBlob], "voice_message.webm", { type: 'audio/webm' });
        sendMedia(file, '');
        stream.getTracks().forEach(track => track.stop());
      };

      mediaRecorder.start(200);
      setIsRecording(true);
      setRecordingTime(0);
      recordingTimerRef.current = setInterval(() => setRecordingTime(t => t + 1), 1000);
      recordingStatusRef.current = 'recording';
    } catch (e) {
      // alert("Microphone access denied"); // Optional, but keeping basic feedback
      recordingStatusRef.current = 'idle';
    }
  };

  const editMessage = async (msg: Message, newText: string) => {
    if (!activeChat || !userId || !keys) return;

    // Encrypt new text
    let encryptedContent = '';
    try {
      if (!activeChat.friendKey) return;
      // IMPORTANT: Pass keys.publicKey for self-recovery (so you can decrypt your own messages)
      encryptedContent = await encryptMessage(activeChat.friendKey, newText, keys?.publicKey);
    } catch (encErr) {
      setToast('Encryption failed');
      return;
    }

    // Update locally immediately (Optimistic)
    const updateLocal = (list: Chat[]) => list.map(c => {
      if (c.chatId === activeChat.chatId) {
        return { ...c, messages: c.messages.map(m => m.id === msg.id ? { ...m, encryptedContent } : m) };
      }
      return c;
    });
    setChats(prev => updateLocal(prev));
    setActiveChat(prev => prev ? ({ ...prev, messages: prev.messages.map(m => m.id === msg.id ? { ...m, encryptedContent } : m) }) : null);
    setDecryptedMessages(prev => ({ ...prev, [msg.id]: newText }));
    setEditingMessage(null);
    setMessage('');

    // Send to server
    chatChannelsRef.current.get(activeChat.chatId)?.push('message-edited', { chatId: activeChat.chatId, messageId: msg.id, encryptedContent });
  };

  const deleteMessage = async (msgId: string) => {
    if (!activeChat) return;

    // Optimistic Delete
    const updateLocal = (list: Chat[]) => list.map(c => {
      if (c.chatId === activeChat.chatId) {
        return { ...c, messages: c.messages.filter(m => m.id !== msgId) };
      }
      return c;
    });
    setChats(prev => updateLocal(prev));
    setActiveChat(prev => prev ? ({ ...prev, messages: prev.messages.filter(m => m.id !== msgId) }) : null);

    // Send to server
    chatChannelsRef.current.get(activeChat.chatId)?.push('message-deleted', { chatId: activeChat.chatId, messageId: msgId });
  };

  const stopRecording = () => {
    if (recordingStatusRef.current === 'starting') {
      recordingStatusRef.current = 'stopping';
      return;
    }
    if (mediaRecorderRef.current && (isRecording || recordingStatusRef.current === 'recording')) {
      Haptics.medium();
      try {
        if (mediaRecorderRef.current.state !== 'inactive') {
          mediaRecorderRef.current.stop();
        }
      } catch (e) {
        console.warn('Error stopping recorder:', e);
      } finally {
        // Always close the UI
        setIsRecording(false);
        clearInterval(recordingTimerRef.current);
        recordingStatusRef.current = 'idle';
      }
    }
  };

  const cancelRecording = () => {
    if (recordingStatusRef.current === 'starting') {
      recordingStatusRef.current = 'cancelling';
      return;
    }
    if (mediaRecorderRef.current && (isRecording || recordingStatusRef.current === 'recording')) {
      const stream = mediaRecorderRef.current.stream;

      // Override onstop to ensure we don't send, just cleanup
      mediaRecorderRef.current.onstop = () => {
        stream?.getTracks().forEach(t => t.stop());
      };

      try {
        if (mediaRecorderRef.current.state !== 'inactive') {
          mediaRecorderRef.current.stop();
        } else {
          // Already inactive, manually clean tracks
          stream?.getTracks().forEach(t => t.stop());
        }
      } catch (e) {
        console.warn('Error cancelling recorder:', e);
        stream?.getTracks().forEach(t => t.stop());
      } finally {
        setIsRecording(false);
        clearInterval(recordingTimerRef.current);
        recordingStatusRef.current = 'idle';
      }
    }
  };



  const blockContact = () => {
    if (!activeChat) return;
    deleteChat(activeChat.chatId);
    setToast('User blocked');
    setView('chats');
  };

  // Toggle mute for active contact
  const toggleMute = async (chatId?: string) => {
    // If chatId provided use it, otherwise use activeChat
    const targetId = chatId || activeChat?.chatId;
    if (!targetId) return;

    // Find current mute status
    const chat = chats.find(c => c.chatId === targetId);
    if (!chat) return;

    const newMuted = !chat.muted;

    // Optimistic Update
    setChats(prev => prev.map(c => c.chatId === targetId ? { ...c, muted: newMuted } : c));

    setToast(newMuted ? 'Notifications muted' : 'Notifications enabled');
    setTimeout(() => setToast(null), 2000);

    // Persist mute setting to backend
    try {
      await fetch(`${getApiUrl()}/api/chat/${targetId}/mute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
        body: JSON.stringify({ userId, muted: newMuted })
      });
    } catch (e) {
      console.error('Failed to update mute setting:', e);
      // Revert on failure? Maybe not for now.
    }
  };


  const registerPush = async (uid: string) => {
    try {
      if (!('serviceWorker' in navigator)) return;
      const reg = await navigator.serviceWorker.ready;
      if (!reg.pushManager) return;

      const sub = await reg.pushManager.getSubscription();
      if (sub) {
        await fetch(`${getApiUrl()}/api/subscribe`, {
          method: 'POST', headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
          body: JSON.stringify({ userId: uid, subscription: sub })
        });
        return;
      }
      const res = await fetch(`${getApiUrl()}/api/vapid-key`, { headers: { 'ngrok-skip-browser-warning': 'true' } });
      const { key } = await res.json();
      const convertedKey = urlBase64ToUint8Array(key);
      const newSub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: convertedKey });
      await fetch(`${getApiUrl()}/api/subscribe`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'ngrok-skip-browser-warning': 'true' },
        body: JSON.stringify({ userId: uid, subscription: newSub })
      });
      alert('Notifications Enabled Successfully!');
    } catch (e) { console.error('[PUSH ERROR]', e); }
  };

  const requestNotificationPermission = async () => {
    if (!('Notification' in window)) return alert("This browser does not support notifications.");
    const result = await Notification.requestPermission();
    if (result === 'granted') registerPush(userId!);
  };

  const logout = async () => {
    // Clear session but KEEP keys in backup (for same-device re-login)
    await keyStore.clearSession();
    setUserId(null);
    setChats([]);
    setActiveChat(null);
    setDecryptedMessages({});
    setDecryptedMedia({});
    setView('auth');
  };

  const deleteAccount = async () => {
    if (!confirm('Delete Account? This will permanently delete all your data and encryption keys.')) return;
    if (!userId) return;
    try {
      await fetch(`${getApiUrl()}/api/user/${userId}`, { method: 'DELETE', headers: { 'ngrok-skip-browser-warning': 'true' } });
      // Full wipe - including backed up keys
      await keyStore.clearAll();
      localStorage.removeItem('device_fingerprint');
      setUserId(null);
      setView('auth');
      window.location.reload();
    } catch (e) { alert('Failed'); }
  };

  const handleAuthSuccess = async (data: { userId: string, username: string, secureId: string, loginToken: string, keys: CryptoKeyPair }) => {
    console.log('[handleAuthSuccess] Starting with userId:', data.userId);

    // Verify user still exists (handle stale local storage)
    // Retry a few times for fresh registrations (timing issue)
    let userExists = false;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        console.log(`[handleAuthSuccess] Verifying user (attempt ${attempt + 1})...`);
        const res = await fetch(`${getApiUrl()}/api/user/${data.userId}`, { headers: { 'ngrok-skip-browser-warning': 'true' } });
        if (res.ok) {
          console.log('[handleAuthSuccess] User verified successfully');
          userExists = true;
          break;
        }
        if (res.status === 404 && attempt < 2) {
          console.log('[handleAuthSuccess] User not found, retrying in 500ms...');
          await new Promise(r => setTimeout(r, 500));
          continue;
        }
        if (res.status === 404) {
          console.warn("[handleAuthSuccess] User not found on server after retries. Clearing stale session.");
          await logout();
          return;
        }
      } catch (e) {
        console.warn("[handleAuthSuccess] Failed to verify user existence:", e);
        // Network error - continue anyway, don't block the user
        userExists = true;
        break;
      }
    }

    if (!userExists) {
      console.warn("[handleAuthSuccess] User verification failed, proceeding anyway for fresh signup");
    }

    console.log('[handleAuthSuccess] Setting user state...');
    setUserId(data.userId);
    setUsername(data.username);
    setLoginToken(data.loginToken);
    setKeys(data.keys);

    // CRITICAL: Ensure ConnectionManager has the token explicitly
    // This fixes the "No auth token available" race condition
    if (data.loginToken) {
      console.log('[handleAuthSuccess] Explicitly setting token in ConnectionManager');
      ConnectionManager.getInstance().setToken(data.loginToken);
    }

    if (socket) {
      if (!socket.isConnected()) {
        socket.connect();
      }
      joinUserChannel(data.userId, socket);
    } else {
      // Force a connection attempt now that we have the token
      console.log('[handleAuthSuccess] Forcing ConnectionManager connect...');
      ConnectionManager.getInstance().forceReconnect(data.loginToken);
    }

    P2PManager.getInstance().init(data.userId);


    loadChats(data.userId);
    console.log('[handleAuthSuccess] Setting view to chats');
    setView('chats');
  };




  // --- RENDER ---
  if (view === 'loading') {
    return (
      <div className="app-container center-content">
        <div className="loading-wave-container">
          <div className="loading-bar"></div>
          <div className="loading-bar"></div>
          <div className="loading-bar"></div>
          <div className="loading-bar"></div>
        </div>
      </div>
    );
  }

  if (view === 'auth') {
    return <Auth onSuccess={handleAuthSuccess} setView={(v: any) => handleViewChange(v)} />;
  }

  if (view === 'connection') {
    return (
      <div className="app-container" style={{ background: 'var(--bg-primary)' }}>
        <ConnectionPage onBack={() => handleViewChange('chats')} />
      </div>
    );
  }

  // Full Screen Call Overlay
  if (view === 'call' && activeChat) {
    return (
      <div className="app-container call-screen">
        <div className="call-content">
          <div className="call-avatar">
            {activeChat.friendImage ? (
              <img src={activeChat.friendImage} alt="" />
            ) : (
              <span>{activeChat.friendName[0].toUpperCase()}</span>
            )}
          </div>
          <h2 className="call-name">{activeChat.friendName}</h2>
          <p className="call-status">Calling...</p>
        </div>
        <div className="call-actions">
          <button className="control-btn end-call" onClick={endCall}>
            <Phone size={28} style={{ transform: 'rotate(135deg)' }} />
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="app-container">
      {incomingCall && (
        <div className="incall-bar">
          <span>Incoming Call...</span>
          <div className="call-actions">
            <button onClick={() => { /* acceptCall */ }} className="btn-accept"><CheckCheck /></button>
            <button onClick={() => setIncomingCall(null)} className="btn-reject"><AlertCircle /></button>
          </div>
        </div>
      )}

      <AnimatePresence initial={false} custom={direction} mode='popLayout'>
        {view === 'chats' && (
          <motion.div
            key="home"
            custom={direction}
            variants={variants}
            initial="initial"
            animate="animate"
            exit="exit"
            transition={{ type: 'tween', duration: 0.3, ease: [0.32, 0.72, 0, 1] }}
            className="view-wrapper"
            style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%' }}
          >
            <Home
              isEditing={isEditing} setIsEditing={setIsEditing}
              connectionStatus={connectionStatus} setView={(v: any) => handleViewChange(v)}
              areChatsLoading={areChatsLoading} chats={chats} userId={userId || ''}
              openChat={(c) => {
                // Ensure openChat triggers forward nav
                setDirection(1);
                openChat(c);
              }}
              deleteChat={deleteChat} typingUsers={typingUsers}
              setShowNewChatModal={setShowNewChatModal} toast={toast}
              chatOptionsChat={chatOptionsChat} setChatOptionsChat={setChatOptionsChat}
              clearChat={clearChat}
              pinChat={pinChat}
              toggleMute={toggleMute}
              username={username}
            />
          </motion.div>
        )}

        {view === 'chat' && activeChat && (
          <motion.div
            key="chat"
            custom={direction}
            variants={variants}
            initial="initial"
            animate="animate"
            exit="exit"
            transition={{ type: 'tween', duration: 0.3, ease: [0.32, 0.72, 0, 1] }}
            className="view-wrapper"
            style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%' }}
          >
            <ActiveChat
              activeChat={activeChat} userId={userId || ''} setView={(v: any) => handleViewChange(v)}
              messagesEndRef={messagesEndRef} message={message} setMessage={setMessage}
              sendMessage={sendMessage} handleTyping={handleTyping} typingUsers={typingUsers} onlineUsers={onlineUsers}
              selectedFile={selectedFile} setSelectedFile={setSelectedFile}
              mediaPreview={mediaPreview} setMediaPreview={setMediaPreview}
              fileInputRef={fileInputRef} textareaRef={textareaRef}
              isRecording={isRecording} startRecording={startRecording} stopRecording={stopRecording}
              cancelRecording={cancelRecording} recordingTime={recordingTime}
              replyingTo={replyingTo} setReplyingTo={setReplyingTo}
              ctxMenu={ctxMenu} setCtxMenu={setCtxMenu} handleCopy={handleCopy}
              getMsgText={getMsgText} decryptedMedia={decryptedMedia} decryptedMessages={decryptedMessages}
              setLightboxImage={setLightboxImage}
              editingMessage={editingMessage}
              setEditingMessage={setEditingMessage}
              onEditMessage={editMessage}
              onDeleteMessage={deleteMessage}
              toast={toast}
              isSearching={showContactSearch}
              setIsSearching={setShowContactSearch}
              searchQuery={contactSearchQuery}
              setSearchQuery={setContactSearchQuery}
              onStartCall={(video) => startCall(activeChat.friendId, video)}
              onClearMessages={() => clearChat(activeChat.chatId)}
              onSendGif={sendGif}
              hasUndecryptableMessages={hasUndecryptableMessages}
              onImportKeys={() => handleViewChange('profile')}
            />
          </motion.div>
        )}

        {view === 'profile' && (
          <motion.div
            key="profile"
            custom={direction}
            variants={variants}
            initial="initial"
            animate="animate"
            exit="exit"
            transition={{ type: 'tween', duration: 0.3, ease: [0.32, 0.72, 0, 1] }}
            className="view-wrapper"
            style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%' }}
          >
            <Profile
              setView={(v: any) => handleViewChange(v)}
              username={username}
              userId={userId || ''}
              connectionStatus={connectionStatus}
              currentServerName={currentServerName}
              isRefreshing={isRefreshing}
              handleRefresh={handleRefresh}
              requestNotificationPermission={requestNotificationPermission}
              logout={logout}
              deleteAccount={deleteAccount}
              setLightboxImage={setLightboxImage}
            />
          </motion.div>
        )}

        {view === 'contact' && activeChat && (
          <motion.div
            key="contact"
            custom={direction}
            variants={variants}
            initial="initial"
            animate="animate"
            exit="exit"
            transition={{ type: 'tween', duration: 0.3, ease: [0.32, 0.72, 0, 1] }}
            className="view-wrapper"
            style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%' }}
          >
            <ContactInfo
              activeChat={activeChat}
              setView={(v: any) => handleViewChange(v)}
              typingUsers={typingUsers}
              startCall={(video) => startCall(activeChat.friendId, video)}
              isMuted={!!activeChat.muted}
              toggleMute={() => toggleMute(activeChat.chatId)}
              blockContact={blockContact}
              clearChat={clearChat}
              deleteChat={deleteChat}
              onSearch={() => { setShowContactSearch(true); handleViewChange('chat'); }}
              setToast={setToast}
            />
          </motion.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {/* Call Overlay */}
        {(incomingCall || activeCall || isCalling) && (
          <CallOverlay
            isActive={!!activeCall || isCalling}
            isIncoming={!!incomingCall}
            friendName={incomingCall ? (chats.find(c => c.friendId === incomingCall.fromId)?.friendName || `Friend ${incomingCall.fromId.slice(-4)}`) : (activeChat?.friendName || 'User')}
            friendImage={activeChat?.friendImage}
            isVideo={isVideoCall || isVideoEnabled}
            onEndCall={endCall}
            onAcceptCall={acceptCall}
            onRejectCall={rejectCall}
            onToggleMute={toggleMuteLocal}
            onToggleVideo={toggleVideoLocal}
            onToggleCamera={toggleCamera}
            isMuted={isMuted}
            isVideoEnabled={isVideoEnabled}
            localStream={callStream}
            remoteStream={remoteStream}
            joinRequests={joinRequests}
            onAcceptJoinRequest={acceptJoinRequest}
            onRejectJoinRequest={rejectJoinRequest}
            onSendJoinRequest={sendJoinRequest}
            isJoinRequestPending={isJoinRequestPending}
            onSendVoiceChunk={(chunk) => {
              const targetId = activeCall?.peer?.replace('SC_V1_', '') || incomingCall?.fromId;
              if (userChannelRef.current && targetId) {
                userChannelRef.current.push('voice-stream', { to: targetId, chunk });
              }
            }}
          />
        )}
      </AnimatePresence>
      <NewChatModal
        isOpen={showNewChatModal}
        onClose={() => setShowNewChatModal(false)}
        myId={userId || ''}
        onStartChat={async (userInfo) => {
          setShowNewChatModal(false);
          // Check if exists
          const existing = chats.find(c => c.friendId === userInfo.userId);
          if (existing) {
            openChat(existing);
          } else {
            // Create temporary pending chat
            const pendingId = `pending_${userInfo.userId}`; // Use friendId to ensure uniqueness locally
            const pendingChat: Chat = {
              chatId: pendingId,
              friendId: userInfo.userId,
              friendName: userInfo.name || userInfo.username,
              friendImage: userInfo.profileImage,
              messages: [],
              unreadCount: 0,
              pinned: false,
              muted: false
            };
            // Open immediately without adding to 'chats' list (it will be added when message sent)
            openChat(pendingChat);
          }
        }}
      />

      <AnimatePresence>
        {lightboxImage && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="lightbox"
            onClick={() => setLightboxImage(null)}
          >
            <img src={lightboxImage} alt="Full size" />
            <button className="close-lightbox"><X /></button>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
