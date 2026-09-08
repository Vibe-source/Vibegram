
import React, { useState } from 'react';
import './MessageBubble.css';
import './ChatScreen.css';
import { motion, AnimatePresence, useMotionValue, animate, useTransform } from 'framer-motion';
import { useDrag } from '@use-gesture/react';
import {
    ArrowLeft, ArrowUp, Mic, X, Paperclip, Copy, FileText, ExternalLink,
    AlertCircle, Trash2, Pencil, CornerUpLeft, Search, Check, CheckCheck, Phone, Smile, Lock
} from 'lucide-react';
import Haptics from '../haptics';
import VoiceBubble from './VoiceBubble';
import GifPicker from './GifPicker';
import MessageBubbleTail from './MessageBubbleTail';
import ContentParts, { getVibeContentEnvelope } from './ContentParts';
import ConnectionManager from '../ConnectionManager';
import { Chat, Message } from '../types';
import { formatTime, formatDuration } from '../utils';
import PatternWallpaper from './PatternWallpaper';
import { VIBE_APPEARANCE } from '../theme/appearance';

function agentImageSource(m: Message, decryptedMedia: { [id: string]: string }): string | undefined {
    const decrypted = decryptedMedia[m.id] || decryptedMedia[m.mediaUrl || ''];
    return decrypted || (m.metadata?.isAgentMessage ? m.mediaUrl : undefined);
}

function renderFileAttachment(m: Message) {
    if (!m.mediaUrl) {
        return <div className="msg-error-text">File unavailable</div>;
    }

    const attachment = m.metadata?.attachment;
    const fileName = m.metadata?.fileName || attachment?.name || attachment?.caption || 'Attachment';
    const mimeType = m.metadata?.mimeType || attachment?.mimeType || '';
    const kind =
        mimeType === 'application/pdf' || attachment?.type === 'pdf'
            ? 'PDF'
            : mimeType === 'text/html' || attachment?.type === 'html'
                ? 'HTML'
                : 'File';

    return (
        <a
            className="msg-file-card"
            href={m.mediaUrl}
            target="_blank"
            rel="noopener noreferrer"
        >
            <FileText size={22} aria-hidden="true" />
            <span className="msg-file-card__text">
                <span className="msg-file-card__name">{fileName}</span>
                <span className="msg-file-card__kind">{kind}</span>
            </span>
            <ExternalLink size={16} aria-hidden="true" />
        </a>
    );
}

function emitProviderEvent(chatId: string, payload: Record<string, string>): void {
    const socket = ConnectionManager.getInstance().getSocket();
    if (!socket?.isConnected()) return;

    // Reuse the channel Chat.tsx already holds for the open chat — a second join
    // on the same topic makes Phoenix close the live one (duplicate-join rule).
    const topic = `chat:${chatId}`;
    type JoinedChannel = { topic: string; state: string; push: (event: string, payload: object) => unknown };
    const joined = (socket as unknown as { channels?: JoinedChannel[] }).channels?.find(
        (ch) => ch.topic === topic && ch.state === 'joined'
    );
    if (joined) {
        joined.push('provider-event', payload);
        return;
    }

    const channel = socket.channel(topic, {});
    channel.join()
        .receive('ok', () => {
            channel.push('provider-event', payload)
                .receive('ok', () => channel.leave())
                .receive('error', () => channel.leave())
                .receive('timeout', () => channel.leave());
        })
        .receive('error', () => channel.leave())
        .receive('timeout', () => channel.leave());
}

function handleContentPartAction(chatId: string, messageId: string, actionId: string): void {
    emitProviderEvent(chatId, { type: 'action', actionId, messageId });
}

function handleContentPartCall(chatId: string): void {
    emitProviderEvent(chatId, { type: 'call.requested' });
}

interface ChatInterfaceProps {
    activeChat: Chat;
    userId: string;
    setView: (view: string) => void;
    messagesEndRef: React.RefObject<HTMLDivElement | null>;
    message: string;
    setMessage: (msg: string) => void;
    sendMessage: () => void;
    handleTyping: () => void;
    typingUsers: Set<string>;
    onlineUsers: Set<string>;

    selectedFile: File | null;
    setSelectedFile: (f: File | null) => void;
    mediaPreview: string | null;
    setMediaPreview: (url: string | null) => void;
    fileInputRef: React.RefObject<HTMLInputElement | null>;
    textareaRef: React.RefObject<HTMLTextAreaElement | null>;
    isRecording: boolean;
    startRecording: () => void;
    stopRecording: () => void;
    cancelRecording: () => void;
    recordingTime: number;
    replyingTo: Message | null;
    setReplyingTo: (m: Message | null) => void;
    ctxMenu: { x: number, y: number, m: Message } | null;
    setCtxMenu: (menu: { x: number, y: number, m: Message } | null) => void;
    handleCopy: (m: Message) => void;
    getMsgText: (m: Message) => string | null;
    decryptedMedia: { [id: string]: string };
    decryptedMessages: { [id: string]: string };
    setLightboxImage: (img: string | null) => void;
    editingMessage: Message | null;
    setEditingMessage: (m: Message | null) => void;
    onEditMessage: (m: Message, newText: string) => void;
    onDeleteMessage: (msgId: string) => void;
    toast: string | null;
    isSearching: boolean;
    setIsSearching: (is: boolean) => void;
    searchQuery: string;
    setSearchQuery: (q: string) => void;
    onStartCall: (video: boolean) => void;
    onClearMessages: () => void;
    onSendGif: (gifUrl: string) => void;
    hasUndecryptableMessages?: boolean;
    onImportKeys?: () => void;
}

const MessageRow = React.memo(({
    m, isMe, seqClass, userId, activeChat,
    setReplyingTo, handleContextMenu, handleCopy,
    handlePointerDown, handlePointerMove, handlePointerUp,
    isSearching, setIsSearching, setSearchQuery,
    getMsgText, decryptedMedia, setLightboxImage,
}: {
    m: Message, isMe: boolean, seqClass: string, userId: string, activeChat: Chat,
    setReplyingTo: any, handleContextMenu: any, handleCopy: any,
    handlePointerDown: any, handlePointerMove: any, handlePointerUp: any,
    isSearching: boolean, setIsSearching: any, setSearchQuery: any,
    getMsgText: any, decryptedMedia: any, setLightboxImage: any
}) => {
    const x = useMotionValue(0);
    const replyOpacity = useTransform(x, [-60, -20], [1, 0]);
    const replyScale = useTransform(x, [-60, -20], [1, 0.5]);
    const replyTranslate = useTransform(x, [-60, 0], [0, 20]);

    const bind = useDrag(({ active, movement: [mx], cancel }) => {
        if (mx > 0) {
            cancel();
            return;
        }

        if (active) {
            const damped = -Math.pow(Math.abs(mx), 0.85);
            x.set(damped);
        } else {
            if (mx < -50) {
                Haptics.medium();
                setReplyingTo(m);
            }
            animate(x, 0, { type: "spring", stiffness: 400, damping: 30 });
        }
    }, {
        axis: 'x',
        filterTaps: true,
        pointer: { touch: true },
        threshold: 15, // Increased threshold to prevent accidental Y scroll locks
        from: () => [x.get(), 0]
    });

    const renderMessageContent = (m: Message) => {
        const msgText = m.type === 'text' ? getMsgText(m) : null;
        const isEncrypted = msgText === 'Unable to decrypt' || msgText === '🔒 Encrypted';

        if (m.type === 'text') {
            // Show locked/blurred message for undecryptable messages
            if (isEncrypted) {
                return (
                    <div className="msg-encrypted">
                        <span className="msg-encrypted-content">Message content here</span>
                        <div className="msg-encrypted-overlay">
                            <Lock size={14} className="msg-encrypted-icon" />
                            <span className="msg-encrypted-text">Import keys to read</span>
                        </div>
                    </div>
                );
            }
            // Show message text directly (no per-bubble loading)
            return <span className="msg-text">{msgText || ''}</span>;
        }

        if (m.type === 'image' || m.type === 'gif') {
            const imageSource = agentImageSource(m, decryptedMedia);
            return (
                <div className="msg-media">
                    {imageSource || m.mediaUrl ? (
                        imageSource ? (
                            <img
                                src={imageSource}
                                alt={m.type === 'gif' ? 'GIF' : 'Photo'}
                                className="msg-image"
                                onClick={() => setLightboxImage(imageSource)}
                            />
                        ) : (
                            <div className="media-skeleton"><div className="media-skeleton-inner"></div></div>
                        )
                    ) : (
                        <div className="msg-error-text">Image Unavailable</div>
                    )}
                </div>
            );
        }

        if (m.type === 'voice') {
            return <VoiceBubble src={decryptedMedia[m.id] || decryptedMedia[m.mediaUrl || '']} />;
        }

        if (m.type === 'file') {
            return renderFileAttachment(m);
        }

        if (m.type === 'call') {
            const info = m.plaintext ? JSON.parse(m.plaintext) : {};
            const isMissed = info.status === 'missed';
            return (
                <div className={`msg-call-info ${isMissed ? 'missed' : ''}`}>
                    <div className="call-icon-bubble">
                        <Phone size={16} />
                    </div>
                    <div className="call-info-text">
                        <span className="call-status-label">{info.status === 'missed' ? 'Missed Call' : (info.status === 'rejected' ? 'Call Declined' : 'Call Ended')}</span>
                        {info.duration && <span className="call-duration-label">{info.duration}</span>}
                    </div>
                </div>
            );
        }

        return <span className="msg-text">Unsupported message type</span>;
    };

    return (
        <div style={{ position: 'relative', width: '100%', marginBottom: 3 }}>
            {/* Reply Icon Container - Fixed Right */}
            <motion.div
                style={{
                    position: 'absolute',
                    right: 16,
                    top: '50%',
                    marginTop: -10,
                    opacity: replyOpacity,
                    scale: replyScale,
                    x: replyTranslate,
                    zIndex: 0,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center'
                }}
            >
                <div style={{
                    width: 32, height: 32, borderRadius: '50%', background: 'var(--bg-card)',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    boxShadow: '0 2px 8px rgba(0,0,0,0.1)'
                }}>
                    <CornerUpLeft size={18} color="var(--accent)" />
                </div>
            </motion.div>

            <motion.div
                key={m.id}
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                transition={{ duration: 0.15 }}
                data-message-id={m.id}
                className={`msg-row ${isMe ? 'msg-row--sent' : 'msg-row--received'} ${seqClass}`}
                style={{ x, touchAction: 'pan-y', background: 'transparent' }}
                {...(bind() as any)}
                onClick={() => {
                    if (isSearching) {
                        setIsSearching(false);
                        setSearchQuery('');
                        setTimeout(() => {
                            const el = document.querySelector(`[data-message-id="${m.id}"]`);
                            if (el) {
                                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                                el.classList.add('highlight-message');
                                setTimeout(() => el.classList.remove('highlight-message'), 2000);
                            }
                        }, 100);
                    }
                }}
            >
                <div
                    className={`msg-box ${isMe ? 'msg-box--sent' : 'msg-box--received'} ${m.type === 'image' ? 'msg-box--image' : ''} ${m.status === 'error' ? 'msg-box--error' : ''}`}
                    onContextMenu={(e) => handleContextMenu(e, m, isMe)}
                    onPointerDown={(e) => {
                        if (e.isPrimary) handlePointerDown(e, m, isMe);
                    }}
                    onPointerMove={handlePointerMove}
                    onPointerUp={handlePointerUp}
                    onPointerLeave={handlePointerUp}
                    onPointerCancel={handlePointerUp}
                    onDoubleClick={() => handleCopy(m)}
                >
                    <MessageBubbleTail
                        isMe={isMe}
                        cornerRadius={VIBE_APPEARANCE.messageCornerRadius}
                        curvature={VIBE_APPEARANCE.messageTailCurvature}
                    />
                    {m.replyToId && (() => {
                        const repliedMsg = activeChat.messages.find(rm => rm.id === m.replyToId);
                        const rText = repliedMsg ? (repliedMsg.type === 'text' ? getMsgText(repliedMsg) : (repliedMsg.type === 'image' ? 'Photo' : 'Voice')) : 'Deleted';
                        const rName = repliedMsg ? (repliedMsg.fromId === userId ? 'You' : activeChat.friendName) : '';
                        return (
                            <div className="msg-reply-preview">
                                <span className="msg-reply-name">{rName}</span>
                                <span className="msg-reply-text">{rText}</span>
                            </div>
                        );
                    })()}

                    {renderMessageContent(m)}

                    {/* vibe.content.v1 rich parts under bubble text */}
                    {(() => {
                        const envelope = getVibeContentEnvelope(
                            m as Message & { metadata?: { content?: unknown } }
                        );
                        if (!envelope) return null;
                        return (
                            <ContentParts
                                content={envelope}
                                accent={VIBE_APPEARANCE.accent}
                                onAction={(actionId) => handleContentPartAction(activeChat.chatId, m.id, actionId)}
                                onCall={() => handleContentPartCall(activeChat.chatId)}
                            />
                        );
                    })()}

                    <div className="msg-time">
                        {formatTime(m.timestamp)}
                        {isMe && (
                            <span className="msg-tick msg-tick-flex">
                                {m.status === 'sending' ? (
                                    <div className="msg-tick-pending" style={{ width: 10, height: 10, border: '1.5px solid rgba(255,255,255,0.5)', borderTopColor: 'transparent', borderRadius: '50%' }} />
                                ) : m.status === 'read' ? (
                                    <CheckCheck size={14} strokeWidth={2} color="#4ade80" />
                                ) : (
                                    <Check size={14} strokeWidth={2} color="rgba(255,255,255,0.7)" />
                                )}
                            </span>
                        )}
                    </div>

                    {m.status === 'error' && isMe && (
                        <AlertCircle size={14} className="msg-error-icon" />
                    )}
                </div>
            </motion.div >
        </div >
    );
});

const ChatInterface: React.FC<ChatInterfaceProps> = ({
    activeChat, userId, setView, messagesEndRef, message, setMessage, sendMessage, handleTyping,
    typingUsers, onlineUsers, selectedFile, setSelectedFile, mediaPreview, setMediaPreview,
    fileInputRef, textareaRef, isRecording, startRecording, stopRecording, cancelRecording,
    recordingTime, replyingTo, setReplyingTo, ctxMenu: _ctxMenu, setCtxMenu: _setCtxMenu, handleCopy, getMsgText,
    decryptedMedia, setLightboxImage, editingMessage, setEditingMessage, onEditMessage, onDeleteMessage, toast,
    isSearching, setIsSearching, searchQuery, setSearchQuery,
    onSendGif, hasUndecryptableMessages, onImportKeys
}) => {
    // GIF picker state
    const [isGifPickerOpen, setIsGifPickerOpen] = useState(false);

    // Helper to render message content for both list and context menu
    const renderMessageContent = (m: Message) => {
        const msgText = m.type === 'text' ? getMsgText(m) : null;
        const isEncrypted = msgText === 'Unable to decrypt' || msgText === '🔒 Encrypted';

        if (m.type === 'text') {
            // Show locked/blurred message for undecryptable messages
            if (isEncrypted) {
                return (
                    <div className="msg-encrypted">
                        <span className="msg-encrypted-content">Message content here</span>
                        <div className="msg-encrypted-overlay">

                            <span className="msg-encrypted-text">Import keys to read</span>
                        </div>
                    </div>
                );
            }
            // Show message text directly (no per-bubble loading)
            return <span className="msg-text">{msgText || ''}</span>;
        }

        if (m.type === 'image' || m.type === 'gif') {
            const imageSource = agentImageSource(m, decryptedMedia);
            return (
                <div className="msg-media">
                    {imageSource ? (
                        <img
                            src={imageSource}
                            alt={m.type === 'gif' ? 'GIF' : 'Photo'}
                            className="msg-image"
                            onClick={() => setLightboxImage(imageSource)}
                        />
                    ) : (
                        <div className="media-skeleton"><div className="media-skeleton-inner"></div></div>
                    )}
                </div>
            );
        }

        if (m.type === 'voice') {
            return <VoiceBubble src={decryptedMedia[m.id] || decryptedMedia[m.mediaUrl || '']} />;
        }

        if (m.type === 'file') {
            return renderFileAttachment(m);
        }

        if (m.type === 'call') {
            const info = m.plaintext ? JSON.parse(m.plaintext) : {};
            const isMissed = info.status === 'missed';
            return (
                <div className={`msg-call-info ${isMissed ? 'missed' : ''}`}>
                    <div className="call-icon-bubble">
                        <Phone size={16} />
                    </div>
                    <div className="call-info-text">
                        <span className="call-status-label">{info.status === 'missed' ? 'Missed Call' : (info.status === 'rejected' ? 'Call Declined' : 'Call Ended')}</span>
                        {info.duration && <span className="call-duration-label">{info.duration}</span>}
                    </div>
                </div>
            );
        }

        return <span className="msg-text">Unsupported message type</span>;
    };

    // Local Context Menu State for "Hold to Pop"
    const [contextMenu, setContextMenu] = React.useState<{
        message: Message;
        rect: DOMRect;
        content: React.ReactNode; // Store the bubble content to clone visually
        isMe: boolean;
    } | null>(null);



    // Scroll to bottom on message change
    const isFirstLoad = React.useRef(true);
    React.useEffect(() => {
        if (messagesEndRef.current) {
            // Small timeout to allow DOM layout
            setTimeout(() => {
                const container = messagesEndRef.current?.parentElement;
                if (container) {
                    if (isFirstLoad.current) {
                        container.scrollTop = container.scrollHeight;
                        isFirstLoad.current = false;
                    } else {
                        container.scrollTo({ top: container.scrollHeight, behavior: 'smooth' });
                    }
                } else {
                    // Fallback
                    messagesEndRef.current?.scrollIntoView({ behavior: isFirstLoad.current ? 'auto' : 'smooth', block: 'end' });
                    if (isFirstLoad.current) isFirstLoad.current = false;
                }
            }, 50);
        }
    }, [activeChat.messages.length, activeChat.chatId]);

    // Scroll to Bottom Button Logic
    const [showScrollButton, setShowScrollButton] = React.useState(false);
    const viewportRef = React.useRef<HTMLDivElement>(null);

    const handleScroll = () => {
        if (!viewportRef.current) return;
        const { scrollTop, scrollHeight, clientHeight } = viewportRef.current;
        const isNearBottom = scrollHeight - scrollTop - clientHeight < 300;
        setShowScrollButton(!isNearBottom);
    };

    const scrollToBottom = () => {
        viewportRef.current?.scrollTo({ top: viewportRef.current.scrollHeight, behavior: 'smooth' });
    };

    // Long Press Logic for Mobile Context Menu
    const longPressTimer = React.useRef<any>(null);
    const startPos = React.useRef<{ x: number, y: number } | null>(null);

    const clearLongPress = React.useCallback(() => {
        if (longPressTimer.current) {
            clearTimeout(longPressTimer.current);
            longPressTimer.current = null;
        }
        startPos.current = null;
    }, []);

    const handlePointerDown = React.useCallback((e: React.PointerEvent, m: Message, isMe: boolean) => {
        if (e.button !== 0) return;
        startPos.current = { x: e.clientX, y: e.clientY };
        const target = e.currentTarget as HTMLElement;
        longPressTimer.current = setTimeout(() => {
            try {
                Haptics.medium();
                if (target && target.getBoundingClientRect) {
                    const rect = target.getBoundingClientRect();
                    setContextMenu({ message: m, rect, content: null, isMe });
                }
            } catch (e) {
                console.error("Context Menu Error:", e);
            }
        }, 400);
    }, []);

    const handlePointerMove = React.useCallback((e: React.PointerEvent) => {
        if (!longPressTimer.current || !startPos.current) return;
        const moveX = Math.abs(e.clientX - startPos.current.x);
        const moveY = Math.abs(e.clientY - startPos.current.y);
        if (moveX > 20 || moveY > 20) {
            clearLongPress();
        }
    }, [clearLongPress]);

    const handlePointerUp = React.useCallback(() => {
        clearLongPress();
    }, [clearLongPress]);

    const handleContextMenu = React.useCallback((e: React.MouseEvent, m: Message, isMe: boolean) => {
        e.preventDefault();
        setContextMenu(prev => {
            if (!prev) {
                const target = e.currentTarget as HTMLElement;
                const rect = target.getBoundingClientRect();
                return { message: m, rect, content: null, isMe };
            }
            return prev;
        });
    }, []);

    const closeContextMenu = React.useCallback(() => setContextMenu(null), []);

    // Filter messages if searching
    const filteredMessages = React.useMemo(() => {
        if (!activeChat) return [];
        if (!isSearching || !searchQuery.trim()) return activeChat.messages;

        const lower = searchQuery.toLowerCase();
        return activeChat.messages.filter(m => {
            if (m.type === 'text') {
                const text = getMsgText(m);
                return text && text.toLowerCase().includes(lower);
            }
            return false;
        });
    }, [activeChat, isSearching, searchQuery, getMsgText]);

    // Swipe to go back gesture
    const bindBackSwipe = useDrag(({ movement: [mx, my], cancel, velocity: [] }) => {
        // Only allow horizontal swipes, ignore vertical scrolling
        // If swiping right (mx > 0)
        if (mx > 60 && Math.abs(mx) > Math.abs(my)) {
            // Go Back
            cancel(); // stop tracking
            setView('chats');
        }
    }, {
        axis: 'x',
        pointer: { touch: true },
        filterTaps: true,
        from: () => [0, 0]
    });

    // Hold-to-Record Logic (Mimicking Mobile)
    const bindMic = useDrag(({ first, last, movement: [mx], }) => {
        if (first) {
            startRecording();
        }
        if (last) {
            if (mx < -100) {
                cancelRecording();
            } else {
                stopRecording();
            }
        }
    }, {
        pointer: { touch: true },
        filterTaps: false,
        preventScroll: true
    });

    return (
        <motion.div
            key="chat"
            className="chat-screen-root"
            onClick={closeContextMenu}
            {...(bindBackSwipe() as any)}
            style={{ touchAction: 'pan-y' }} // Important: Allow vertical scroll for messages
        >
            <PatternWallpaper />
            {/* Gradient Masks */}
            <div className="chat-header-mask" />
            {/* Footer mask is handled by input-area-container */}

            {/* Header Deck */}
            <header className="chat-header-deck">
                {isSearching ? (
                    <div className="chat-header-search-row">
                        <div className="chat-search-input-wrapper-glass">
                            <Search size={16} color="var(--text-secondary)" />
                            <input
                                autoFocus
                                type="text"
                                placeholder="Search..."
                                value={searchQuery}
                                onChange={(e) => setSearchQuery(e.target.value)}
                                className="chat-search-input"
                            />
                        </div>
                        <button
                            type="button"
                            className="icon-btn chat-search-close-btn"
                            onClick={() => { setIsSearching(false); setSearchQuery(''); }}
                        >
                            <X size={18} />
                        </button>
                    </div>
                ) : (
                    <>
                        <button type="button" className="icon-btn" onClick={() => setView('chats')}>
                            <ArrowLeft size={18} />
                        </button>
                        <div className="header-title-area header-title-container" onClick={() => setView('contact')}>
                            <div className="header-title-column">
                                <h2 className="header-title-text">{activeChat?.friendName}</h2>
                                {activeChat?.friendId && typingUsers.has(activeChat.friendId.toUpperCase()) ? (
                                    <span className="typing-shine header-typing-status">typing…</span>
                                ) : (
                                    activeChat?.friendId && onlineUsers.has(activeChat.friendId.toUpperCase()) ? (
                                        <span className="header-last-seen header-online">Online</span>
                                    ) : (
                                        <span className="header-last-seen">Last seen recently</span>
                                    )
                                )}
                            </div>
                        </div>
                        <div className="header-actions-right">
                            <div onClick={() => setView('contact')} className="header-contact-btn" role="button" tabIndex={0}>
                                {activeChat?.friendImage ? (
                                    <div className="header-avatar-circle">
                                        <img src={activeChat.friendImage} className="header-avatar-img" alt="" />
                                    </div>
                                ) : (
                                    <div
                                        className="header-avatar-circle header-avatar-fallback"
                                        style={{
                                            background: `linear-gradient(135deg, var(--bubble-me-solid, #8B7CFF), var(--bubble-me, #08C6B4))`,
                                        }}
                                    >
                                        {(activeChat?.friendName || '?')[0]?.toUpperCase()}
                                    </div>
                                )}
                            </div>
                        </div>
                    </>
                )}
            </header>

            {/* Scrollable Viewport */}
            < div className="chat-viewport" ref={viewportRef} onScroll={handleScroll} >
                <div className="chat-content-container">
                    {/* Top Spacer for Header */}
                    {/* Top Spacer is handled by padding-top in ChatScreen.css */}{/*  */}

                    {/* Key Import Banner - shown when messages can't be decrypted */}
                    {hasUndecryptableMessages && (
                        <div
                            onClick={onImportKeys}
                            style={{
                                background: 'linear-gradient(135deg, rgba(245, 158, 11, 0.15) 0%, rgba(245, 158, 11, 0.08) 100%)',
                                border: '1px solid rgba(245, 158, 11, 0.3)',
                                borderRadius: 12,
                                padding: '12px 16px',
                                margin: '8px 12px 12px',
                                display: 'flex',
                                alignItems: 'center',
                                gap: 12,
                                cursor: 'pointer'
                            }}
                        >
                            <Lock size={20} color="#f59e0b" />
                            <div style={{ flex: 1 }}>
                                <div style={{ fontWeight: 600, fontSize: 13, color: '#f59e0b', marginBottom: 2 }}>
                                    Some messages are encrypted
                                </div>
                                <div style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                                    Tap to import your keys from another device
                                </div>
                            </div>
                            <ArrowLeft size={16} color="var(--text-secondary)" style={{ transform: 'rotate(180deg)' }} />
                        </div>
                    )}

                    {filteredMessages.length === 0 ? (
                        <div className="empty-state-container" style={{
                            display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
                            height: '100%', paddingBottom: 100, opacity: 1
                        }}>
                            {isSearching && searchQuery.trim() ? (
                                <div style={{ textAlign: 'center' }}>
                                    <div style={{ marginBottom: 16, opacity: 0.5 }}><Search size={48} /></div>
                                    <h3 style={{ margin: '0 0 8px 0', fontSize: 16, fontWeight: 600 }}>No results found</h3>
                                    <p style={{ margin: 0, fontSize: 13, color: 'var(--text-secondary)' }}>
                                        No messages match "{searchQuery}"
                                    </p>
                                </div>
                            ) : (
                                <>

                                    <h3 style={{ margin: '0 0 8px 0', fontSize: 16, fontWeight: 600 }}>No messages yet...</h3>
                                    <p style={{ margin: 0, fontSize: 13, color: 'var(--text-secondary)', textAlign: 'center', maxWidth: 200 }}>
                                        Send a message to start the conversation!
                                    </p>
                                </>
                            )}
                        </div>
                    ) : (
                        filteredMessages.map((m, i) => {
                            const isMe = (m.fromId || '').toUpperCase() === (userId || '').toUpperCase();

                            // Skip rendering if text message hasn't been decrypted yet (no empty bubbles)
                            if (m.type === 'text') {
                                const hasContent = getMsgText(m);
                                if (!hasContent && !isMe) return null; // Don't show empty bubble for received messages
                            }

                            // For sequence calculation, use all messages (not filtered by ready state)
                            const prev = filteredMessages[i - 1];
                            const next = filteredMessages[i + 1];

                            // Sequence Logic based on sender AND time gap
                            const isSequenceStart = !prev || prev.fromId !== m.fromId || (m.timestamp - prev.timestamp > 60000);
                            const isSequenceEnd = !next || next.fromId !== m.fromId || (next.timestamp - m.timestamp > 60000);

                            // We use these classes to shape corners precisely
                            const seqClass = [
                                isSequenceStart ? 'msg-seq-start' : '',
                                !isSequenceStart && !isSequenceEnd ? 'msg-seq-middle' : '',
                                isSequenceEnd ? 'msg-seq-end' : ''
                            ].filter(Boolean).join(' ');

                            return (
                                <MessageRow
                                    key={m.id}
                                    m={m}
                                    isMe={isMe}
                                    seqClass={seqClass}
                                    userId={userId}
                                    activeChat={activeChat}
                                    setReplyingTo={setReplyingTo}
                                    handleContextMenu={handleContextMenu}
                                    handleCopy={handleCopy}
                                    handlePointerDown={handlePointerDown}
                                    handlePointerMove={handlePointerMove}
                                    handlePointerUp={handlePointerUp}
                                    isSearching={isSearching}
                                    setIsSearching={setIsSearching}
                                    setSearchQuery={setSearchQuery}
                                    getMsgText={getMsgText}
                                    decryptedMedia={decryptedMedia}
                                    setLightboxImage={setLightboxImage}
                                />
                            );
                        })
                    )}


                    <div ref={messagesEndRef} />
                </div>
            </div >

            {/* Scroll To Bottom Button */}
            <AnimatePresence>
                {
                    showScrollButton && (
                        <motion.button
                            initial={{ opacity: 0, y: 10 }}
                            animate={{ opacity: 1, y: 0 }}
                            exit={{ opacity: 0, y: 10 }}
                            className="scroll-bottom-btn"
                            onClick={scrollToBottom}
                        >
                            <ArrowUp size={20} style={{ transform: 'rotate(180deg)' }} />
                        </motion.button>
                    )
                }
            </AnimatePresence >

            {/* Input Deck */}
            <footer className="input-area-container">
                <div className={`input-area ${replyingTo || editingMessage ? 'replying' : ''}`} style={{ display: 'flex', alignItems: 'flex-end', gap: 0, }}>

                    {mediaPreview && (
                        <div className="media-preview-container">
                            <img src={mediaPreview} alt="Preview" />
                            <button className="close-preview" onClick={() => {
                                setSelectedFile(null);
                                setMediaPreview(null);
                                if (fileInputRef.current) fileInputRef.current.value = '';
                            }}><X size={20} /></button>
                        </div>
                    )}

                    {!isRecording && (
                        <div style={{ height: 44, display: 'flex', alignItems: 'center', marginRight: 8 }}>
                            <input
                                type="file"
                                ref={fileInputRef}
                                className="file-input-hidden"
                                accept="image/*"
                                onChange={e => {
                                    if (e.target.files?.[0]) {
                                        const file = e.target.files[0];
                                        setSelectedFile(file);
                                        setMediaPreview(URL.createObjectURL(file));
                                    }
                                }}
                            />
                            <button className="attach-btn" onClick={() => fileInputRef.current?.click()}>
                                <Paperclip size={20} />
                            </button>
                        </div>
                    )}

                    <div style={{ flex: 1, minWidth: 0 }}>
                        {isRecording ? (
                            <div className="input-pill-row recording-ui-pill" style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: '0 16px', background: 'rgba(255, 255, 255, 0.05)', borderColor: 'rgba(255, 255, 255, 0.1)', userSelect: 'none', WebkitUserSelect: 'none' }}>
                                <div className="recording-indicator-row">
                                    <div className="recording-dot" style={{ background: '#ef4444', animation: 'pulse 1s infinite' }}></div>
                                    <span className="recording-timer" style={{ color: 'var(--text-primary)' }}>{formatDuration(recordingTime)}</span>
                                </div>
                                <div className="recording-hint" style={{ color: 'var(--text-secondary)', userSelect: 'none' }}>{"< Slide to cancel"}</div>
                            </div>
                        ) : (
                            <div className="input-pill-row" style={{ flexDirection: 'column', alignItems: 'center' }}>
                                {replyingTo && (
                                    <div className="reply-banner reply-banner-anim">
                                        <div className="reply-content">
                                            <div className="reply-header">
                                                <div className="reply-bar" />
                                                <span className="reply-name">
                                                    {replyingTo.fromId === userId ? 'You' : activeChat?.friendName}
                                                </span>
                                            </div>
                                            <span className="reply-text">
                                                {replyingTo.type === 'text' ? getMsgText(replyingTo) : (replyingTo.type === 'image' ? '📷 Photo' : '🎤 Voice Message')}
                                            </span>
                                        </div>
                                        <button
                                            onPointerDown={(e) => { e.preventDefault(); e.stopPropagation(); setReplyingTo(null); }}
                                            className="reply-close-btn"
                                        >
                                            <X size={14} />
                                        </button>
                                    </div>
                                )}

                                {editingMessage && (
                                    <div className="reply-banner editing-banner reply-banner-anim">
                                        <div className="reply-content">
                                            <div className="reply-header">
                                                <Pencil size={12} color="var(--accent)" />
                                                <span className="reply-name editing-label">Editing Message</span>
                                            </div>
                                            <span className="reply-text">
                                                {getMsgText(editingMessage)}
                                            </span>
                                        </div>
                                        <button
                                            onPointerDown={(e) => { e.preventDefault(); e.stopPropagation(); setEditingMessage(null); setMessage(''); }}
                                            className="reply-close-btn"
                                        >
                                            <X size={14} />
                                        </button>
                                    </div>
                                )}

                                <div style={{ display: 'flex', alignItems: 'center', width: '100%' }}>
                                    <textarea
                                        ref={textareaRef}
                                        className="msg-input"
                                        rows={1}
                                        placeholder={selectedFile ? "Add a caption..." : (editingMessage ? "Edit message..." : "Message...")}
                                        value={message}
                                        onChange={e => {
                                            setMessage(e.target.value);
                                            handleTyping();
                                        }}
                                        onKeyDown={e => {
                                            if (e.key === 'Enter' && !e.shiftKey) {
                                                e.preventDefault();
                                                if (editingMessage) {
                                                    onEditMessage(editingMessage, message);
                                                } else {
                                                    sendMessage();
                                                }
                                            }
                                        }}
                                    />

                                    {/* Emoji - Static, always visible */}
                                    <div style={{ width: 40, height: 44, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                                        <button
                                            className="emoji-input-btn"
                                            onClick={() => setIsGifPickerOpen(true)}
                                            style={{
                                                border: 'none', background: 'transparent', padding: 0, cursor: 'pointer',
                                                display: 'flex', alignItems: 'center', justifyContent: 'center',
                                                width: '100%', height: '100%'
                                            }}
                                        >
                                            <Smile size={22} color="var(--text-secondary)" strokeWidth={1.5} />
                                        </button>
                                    </div>
                                </div>
                            </div>
                        )}
                    </div>

                    {/* Right Actions - Swaps betwen Mic and Send */}
                    <AnimatePresence mode="popLayout" initial={false}>
                        {((!(message.trim().length > 0 || !!selectedFile)) || isRecording) ? (
                            <motion.div
                                key="mic-btn"
                                initial={{ opacity: 0, scale: 0.5 }}
                                animate={{ opacity: 1, scale: 1 }}
                                exit={{ opacity: 0, scale: 0.5 }}
                                transition={{ type: 'spring', duration: 0.2, bounce: 0 }}
                                style={{ marginLeft: 6 }}
                            >
                                <motion.div
                                    {...bindMic() as any}
                                    className="send-btn"
                                    whileTap={{ scale: 0.9 }}
                                    style={{
                                        width: 44, height: 44, borderRadius: '50%',
                                        background: 'rgba(255,255,255,0.05)',
                                        border: '1px solid rgba(255,255,255,0.1)',
                                        backdropFilter: 'blur(10px)',
                                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                                        cursor: 'pointer', touchAction: 'none'
                                    }}
                                >
                                    <Mic size={20} color={isRecording ? '#ef4444' : "var(--text-primary)"} />
                                </motion.div>
                            </motion.div>
                        ) : (
                            <motion.button
                                key="send-btn"
                                type="button"
                                initial={{ opacity: 0, scale: 0.5 }}
                                animate={{ opacity: 1, scale: 1 }}
                                exit={{ opacity: 0, scale: 0.5 }}
                                transition={{ type: 'spring', duration: 0.2, bounce: 0.3 }}
                                className="send-btn active"
                                onClick={() => editingMessage ? onEditMessage(editingMessage, message) : sendMessage()}
                                style={{
                                    width: 44, height: 44, borderRadius: '50%',
                                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                                    border: 'none', cursor: 'pointer',
                                    marginLeft: 6,
                                    background: 'var(--bubble-me-gradient, var(--accent))',
                                    color: '#04211e',
                                    boxShadow: '0 6px 16px -4px rgba(8, 198, 180, 0.45)'
                                }}
                            >
                                <ArrowUp size={20} strokeWidth={3} color="#04211e" />
                            </motion.button>
                        )}
                    </AnimatePresence>
                </div>
            </footer>



            {/* Bubble Context Menu Overlay */}
            <AnimatePresence>
                {
                    contextMenu && (
                        <motion.div
                            initial={{ opacity: 0 }}
                            animate={{ opacity: 1 }}
                            exit={{ opacity: 0 }}
                            className="context-menu-overlay"
                            onClick={closeContextMenu}
                        >
                            {/* Cloned Bubble Container */}
                            <div
                                className="cloned-bubble-wrapper"
                                style={{
                                    top: contextMenu.rect.top,
                                    left: contextMenu.rect.left,
                                    width: contextMenu.rect.width,
                                    height: contextMenu.rect.height,
                                }}
                            >
                                <motion.div
                                    initial={{ scale: 1 }}
                                    animate={{
                                        scale: 1.05,
                                        boxShadow: '0 8px 30px rgba(0,0,0,0.3)',
                                        zIndex: 2002
                                    }}
                                    exit={{ opacity: 0, scale: 1 }}
                                    className="cloned-bubble-content"
                                    style={{
                                        transformOrigin: contextMenu.isMe ? 'center right' : 'center left',
                                        userSelect: 'none' // Fix for text selection
                                    }}
                                >
                                    {/* Re-render bubble content */}
                                    <div className={`msg-box cloned-bubble-inner ${contextMenu.isMe ? 'msg-box--sent' : 'msg-box--received'} ${contextMenu.message.type === 'image' ? 'msg-box--image' : ''} ${contextMenu.message.status === 'error' ? 'msg-box--error' : ''}`}>
                                        <MessageBubbleTail
                                            isMe={contextMenu.isMe}
                                            cornerRadius={VIBE_APPEARANCE.messageCornerRadius}
                                            curvature={VIBE_APPEARANCE.messageTailCurvature}
                                        />
                                        {renderMessageContent(contextMenu.message)}
                                        {(() => {
                                            const envelope = getVibeContentEnvelope(
                                                contextMenu.message as Message & {
                                                    metadata?: { content?: unknown };
                                                }
                                            );
                                            if (!envelope) return null;
                                            return (
                                                <ContentParts
                                                    content={envelope}
                                                    accent={VIBE_APPEARANCE.accent}
                                                    onAction={(actionId) => handleContentPartAction(activeChat.chatId, contextMenu.message.id, actionId)}
                                                    onCall={() => handleContentPartCall(activeChat.chatId)}
                                                />
                                            );
                                        })()}
                                    </div>
                                </motion.div>
                            </div>

                            {/* Menu Items */}
                            {(() => {
                                const menuHeight = 220;
                                const spaceBelow = window.innerHeight - contextMenu.rect.bottom;
                                const showAbove = spaceBelow < menuHeight;

                                const menuStyle: any = {
                                    left: contextMenu.isMe ? 'auto' : contextMenu.rect.left,
                                    right: contextMenu.isMe ? window.innerWidth - contextMenu.rect.right : 'auto'
                                };

                                // Adjust horizontal
                                if (contextMenu.isMe && window.innerWidth - contextMenu.rect.right < 10) menuStyle.right = 10;
                                if (!contextMenu.isMe && contextMenu.rect.left < 10) menuStyle.left = 10;

                                // Simply place menu 6px away from the rect
                                if (showAbove) {
                                    menuStyle.bottom = window.innerHeight - contextMenu.rect.top + 6;
                                    menuStyle.transformOrigin = 'bottom ' + (contextMenu.isMe ? 'right' : 'left');
                                } else {
                                    menuStyle.top = contextMenu.rect.bottom + 6;
                                    menuStyle.transformOrigin = 'top ' + (contextMenu.isMe ? 'right' : 'left');
                                }

                                return (
                                    <motion.div
                                        initial={{ opacity: 0, scale: 0.95 }}
                                        animate={{ opacity: 1, scale: 1 }}
                                        exit={{ opacity: 0, scale: 0.95 }}
                                        className="context-menu-container"
                                        style={menuStyle}
                                        onClick={(e) => e.stopPropagation()}
                                    >
                                        {/* Copy */}
                                        {contextMenu.message.type === 'text' && (
                                            <button className="context-menu-item" onClick={() => {
                                                handleCopy(contextMenu.message);
                                                closeContextMenu();
                                            }}>
                                                <Copy size={20} strokeWidth={1.5} /> <span>Copy</span>
                                            </button>
                                        )}

                                        {/* Edit (Own Messages Only) */}
                                        {contextMenu.isMe && contextMenu.message.type === 'text' && (
                                            <button className="context-menu-item" onClick={() => {
                                                setEditingMessage(contextMenu.message);
                                                setMessage(getMsgText(contextMenu.message) || '');
                                                // Focus textarea
                                                setTimeout(() => textareaRef.current?.focus(), 100);
                                                closeContextMenu();
                                            }}>
                                                <Pencil size={20} strokeWidth={1.5} /> <span>Edit</span>
                                            </button>
                                        )}

                                        {/* Reply */}
                                        <button className="context-menu-item" onClick={() => {
                                            setReplyingTo(contextMenu.message);
                                            closeContextMenu();
                                        }}>
                                            <CornerUpLeft size={20} strokeWidth={1.5} /> <span>Reply</span>
                                        </button>

                                        <div className="context-menu-divider" />

                                        {/* Delete */}
                                        <button className="context-menu-item danger" onClick={() => {
                                            onDeleteMessage(contextMenu.message.id);
                                            closeContextMenu();
                                        }}>
                                            <Trash2 size={20} strokeWidth={1.5} /> <span>Delete</span>
                                        </button>
                                    </motion.div>
                                );
                            })()}
                        </motion.div>
                    )
                }
            </AnimatePresence >

            {/* Toast with AnimatePresence */}
            <AnimatePresence>
                {
                    toast && (
                        <motion.div
                            initial={{ opacity: 0, y: -20, x: '-50%', scale: 0.9 }}
                            animate={{ opacity: 1, y: 0, x: '-50%', scale: 1 }}
                            exit={{ opacity: 0, y: -10, x: '-50%', scale: 0.9 }}
                            transition={{ duration: 0.3, ease: [0.16, 1, 0.3, 1] }}
                            className="toast-notification toast-no-anim"
                        >
                            {toast}
                        </motion.div>
                    )
                }
            </AnimatePresence >

            {/* GIF Picker */}
            < GifPicker
                isOpen={isGifPickerOpen}
                onClose={() => setIsGifPickerOpen(false)}
                onSelectGif={(gifUrl) => {
                    onSendGif(gifUrl);
                    setIsGifPickerOpen(false);
                }}
            />
        </motion.div >
    );
};

export default ChatInterface;
