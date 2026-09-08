
export interface Message {
    id: string;
    fromId: string;
    encryptedContent: string;
    type: 'text' | 'image' | 'voice' | 'call' | 'gif' | 'file';
    mediaUrl?: string;
    timestamp: number;
    status?: 'sending' | 'pending' | 'sent' | 'delivered' | 'read' | 'error';
    readBy?: string[];
    errorMessage?: string;
    replyToId?: string;
    plaintext?: string; // Optional for decrypted cache
    extra?: string; // For encrypted captions
    metadata?: {
        isAgentMessage?: boolean;
        fileName?: string;
        mimeType?: string;
        caption?: string;
        attachment?: {
            type?: string;
            name?: string;
            mimeType?: string;
            caption?: string;
        };
        [key: string]: unknown;
    };
}

export interface Chat {
    chatId: string;
    friendId: string;
    friendName: string;
    friendKey?: CryptoKey;
    friendIdentityKey?: CryptoKey; // Legacy / P2P
    messages: Message[];
    lastMessage?: Message;
    unreadCount?: number;
    friendImage?: string;
    previewLastMessage?: string; // Cache
    pinned?: boolean;
    muted?: boolean;
}

export interface UserProfile {
    id: string;
    name: string;
    image?: string;
    about?: string;
    lastSeen?: number;
    publicKey?: string;
}
