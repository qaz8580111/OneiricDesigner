/**
 * bilibili_bridge.js - B站直播弹幕/礼物桥接服务
 *
 * 职责：
 *   1. 作为客户端连接B站直播间 WSS，接收原始弹幕/礼物/进房消息
 *   2. 将各平台异构消息转译为统一 JSON 事件协议
 *   3. 作为本地 WebSocket 服务端(端口8899)，供 Godot LiveBridgeManager 连接消费
 *
 * 架构：
 *   B站WSS ←(bilibili-ws-client)─ 桥接进程 ─(ws://127.0.0.1:8899)→ Godot
 *
 * 统一事件协议（输出到Godot的JSON格式）：
 *   {"event":"enter","platform":"bilibili","uid":"123","uname":"游客A"}
 *   {"event":"danmu","platform":"bilibili","uid":"456","uname":"观众B","text":"冲冲冲"}
 *   {"event":"gift","platform":"bilibili","uid":"789","uname":"土豪C","gift_id":"1","gift_name":"辣条","num":1,"value":0.01}
 *
 * 用法：
 *   npm install               # 安装依赖
 *   node bilibili_bridge.js   # 启动（需提供房间号）
 *   node bilibili_bridge.js --room 12345678          # 指定房间号
 *   node bilibili_bridge.js --room 12345678 --port 8899  # 指定端口
 *   node bilibili_bridge.js --mock  # 模拟模式（不连B站，生成假事件用于测试）
 */

import { WebSocketServer } from 'ws';
import Client from 'bilibili-ws-client';

// ========== 命令行参数解析 ==========

const args = process.argv.slice(2);
const roomIdArg = args.find(a => a.startsWith('--room='))?.split('=')[1]
             || args[args.indexOf('--room') + 1];
const portArg = args.find(a => a.startsWith('--port='))?.split('=')[1]
             || args[args.indexOf('--port') + 1];
const isMock = args.includes('--mock');

const ROOM_ID = parseInt(roomIdArg) || 0;
const PORT = parseInt(portArg) || 8899;

// ========== 本地 WebSocket 服务端 ==========
// Godot LiveBridgeManager 连接到此服务端，消费统一 JSON 事件

const wss = new WebSocketServer({ port: PORT });
const clients = new Set(); // 已连接的 Godot 客户端集合

wss.on('connection', (ws) => {
    clients.add(ws);
    console.log(`[Bridge] Godot 客户端已连接，当前连接数: ${clients.size}`);
    
    // 发送连接确认消息
    sendToClient(ws, {
        event: 'bridge_connected',
        platform: 'system',
        timestamp: Date.now()
    });
    
    ws.on('close', () => {
        clients.delete(ws);
        console.log(`[Bridge] Godot 客户端断开，剩余连接数: ${clients.size}`);
    });
    
    ws.on('error', (err) => {
        console.error('[Bridge] Godot 客户端错误:', err.message);
        clients.delete(ws);
    });
});

// 向单个客户端发送 JSON 消息
function sendToClient(ws, data) {
    if (ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify(data));
    }
}

// 向所有已连接的 Godot 客户端广播统一事件
function broadcastEvent(eventData) {
    const msg = JSON.stringify(eventData);
    for (const ws of clients) {
        if (ws.readyState === ws.OPEN) {
            ws.send(msg);
        }
    }
}

// ========== B站 WSS 连接（非模拟模式） ==========

if (!isMock && ROOM_ID > 0) {
    console.log(`[Bridge] 正在连接B站直播间 ${ROOM_ID}...`);
    
    // buvid 需要通过 B站 API 获取（访客模式，匿名连接）
    // 这里先用空值，bilibili-ws-client 会尝试匿名连接
    const sub = new Client({
        uid: 0,           // 0 = 访客，不显示弹幕发送用户
        roomid: ROOM_ID,
        protover: 3,      // 协议版本3，支持brotli压缩
        buvid: '',        // 留空，匿名连接
        platform: 'web',
        type: 2,
        key: '',          // token，匿名时留空
    });
    
    sub.on('open', () => {
        console.log('[Bridge] B站 WSS 连接成功，认证完成');
    });
    
    sub.on('close', () => {
        console.log('[Bridge] B站 WSS 连接关闭，等待自动重连...');
    });
    
    sub.on('error', (err) => {
        console.error('[Bridge] B站 WSS 连接错误:', err.message);
    });
    
    // 核心消息处理：将B站异构消息转译为统一 JSON 事件
    sub.on('message', ({ ver, op, cmd, body, ts }) => {
        // op=5 是业务消息（弹幕/礼物/进房等）
        if (op !== 5 || !cmd) return;
        
        try {
            handleBilibiliMessage(cmd, body);
        } catch (e) {
            // 单条消息解析失败不应影响整体连接
            console.error('[Bridge] 消息解析失败:', cmd, e.message);
        }
    });
    
} else if (isMock) {
    // ========== 模拟模式（不连B站，生成假事件用于开发测试） ==========
    console.log('[Bridge] 模拟模式启动——生成假事件供 Godot 调试');
    startMockEventGenerator();
    
} else {
    console.error('[Bridge] 错误：未提供房间号！用法: node bilibili_bridge.js --room=12345678');
    console.error('[Bridge] 或使用模拟模式: node bilibili_bridge.js --mock');
    process.exit(1);
}

// ========== B站消息转译逻辑 ==========

/**
 * 将B站原始消息转译为统一 JSON 事件并广播
 * B站消息格式参考：
 *   DANMU_MSG: body.info[1]=弹幕文本, body.info[2][1]=用户名, body.info[2][0]=uid
 *   SEND_GIFT: body.data.uname, body.data.uid, body.data.giftName, body.data.num, body.data.price(分)
 *   INTERACT_WORD: body.data.uname, body.data.uid, body.data.msg_type(1=进房,2=关注,3=分享)
 *   WELCOME: 旧版进房消息（兼容）
 */
function handleBilibiliMessage(cmd, body) {
    switch (cmd) {
        case 'DANMU_MSG': {
            // 弹幕消息
            const info = body?.info;
            if (!info) return;
            const text = info[1] || '';
            const uid = info[2]?.[0]?.toString() || '0';
            const uname = info[2]?.[1] || '匿名用户';
            broadcastEvent({
                event: 'danmu',
                platform: 'bilibili',
                uid: uid,
                uname: uname,
                text: text,
                timestamp: Date.now()
            });
            break;
        }
        
        case 'SEND_GIFT': {
            // 礼物消息
            const data = body?.data;
            if (!data) return;
            // B站price单位是分（1元=100分），折算为元
            // coin_type: silver=银瓜子(免费礼物), gold=金瓜子(付费礼物)
            const valueYuan = (data.price || 0) / 100;
            broadcastEvent({
                event: 'gift',
                platform: 'bilibili',
                uid: data.uid?.toString() || '0',
                uname: data.uname || '匿名用户',
                gift_id: data.giftId?.toString() || '0',
                gift_name: data.giftName || '未知礼物',
                num: data.num || 1,
                value: valueYuan,
                coin_type: data.coin_type || 'silver',
                timestamp: Date.now()
            });
            break;
        }
        
        case 'INTERACT_WORD': {
            // 互动消息：msg_type 1=进入房间, 2=关注, 3=分享
            const data = body?.data;
            if (!data) return;
            if (data.msg_type === 1) {
                // 仅处理进房事件（关注/分享可选处理）
                broadcastEvent({
                    event: 'enter',
                    platform: 'bilibili',
                    uid: data.uid?.toString() || '0',
                    uname: data.uname || '匿名用户',
                    timestamp: Date.now()
                });
            }
            break;
        }
        
        // 以下消息可选处理（暂不转发，可按需扩展）
        case 'WELCOME': {
            // 旧版进房消息（兼容旧协议）
            const data = body?.data;
            if (!data) return;
            broadcastEvent({
                event: 'enter',
                platform: 'bilibili',
                uid: data.uid?.toString() || '0',
                uname: data.uname || '匿名用户',
                timestamp: Date.now()
            });
            break;
        }
        
        case 'LIKE_INFO': {
            // 点赞消息（可选处理）
            const data = body?.data;
            if (!data) return;
            // 点赞暂不生成敌人，可作为计数参考
            break;
        }
        
        default:
            // 未识别的消息类型静默忽略
            break;
    }
}

// ========== 模拟事件生成器（开发调试用） ==========

const mockUnames = ['测试观众A', '路人甲', '土豪B', '萌新C', '大佬D', '潜水员E', '吃瓜群众F'];
const mockGifts = [
    { gift_name: '辣条', num: 1, value: 0.01, coin_type: 'silver' },
    { gift_name: '小心心', num: 1, value: 0.1, coin_type: 'gold' },
    { gift_name: 'BKT', num: 1, value: 5.0, coin_type: 'gold' },
    { gift_name: '干杯', num: 10, value: 10.0, coin_type: 'gold' },
    { gift_name: '舰长', num: 1, value: 198.0, coin_type: 'gold' },
];

function startMockEventGenerator() {
    // 模拟进房事件：每2-5秒一个新观众
    setInterval(() => {
        broadcastEvent({
            event: 'enter',
            platform: 'bilibili',
            uid: String(Math.floor(Math.random() * 1000000)),
            uname: mockUnames[Math.floor(Math.random() * mockUnames.length)],
            timestamp: Date.now()
        });
    }, 2000 + Math.random() * 3000);
    
    // 模拟弹幕事件：每1-3秒一条弹幕
    setInterval(() => {
        broadcastEvent({
            event: 'danmu',
            platform: 'bilibili',
            uid: String(Math.floor(Math.random() * 1000000)),
            uname: mockUnames[Math.floor(Math.random() * mockUnames.length)],
            text: ['冲冲冲', '6666', '哈哈哈', '主播好强', '我是谁', '好难啊'][Math.floor(Math.random() * 6)],
            timestamp: Date.now()
        });
    }, 1000 + Math.random() * 2000);
    
    // 模拟礼物事件：每5-10秒一个礼物
    setInterval(() => {
        const gift = mockGifts[Math.floor(Math.random() * mockGifts.length)];
        broadcastEvent({
            event: 'gift',
            platform: 'bilibili',
            uid: String(Math.floor(Math.random() * 1000000)),
            uname: mockUnames[Math.floor(Math.random() * mockUnames.length)],
            gift_id: String(Math.floor(Math.random() * 100)),
            gift_name: gift.gift_name,
            num: gift.num,
            value: gift.value,
            coin_type: gift.coin_type,
            timestamp: Date.now()
        });
    }, 5000 + Math.random() * 5000);
}

// ========== 进程信号处理 ==========

process.on('SIGINT', () => {
    console.log('\n[Bridge] 正在关闭桥接服务...');
    for (const ws of clients) {
        ws.close();
    }
    wss.close();
    process.exit(0);
});

console.log(`[Bridge] 本地 WebSocket 服务端已启动，监听端口 ${PORT}`);
console.log('[Bridge] Godot 端请连接 ws://127.0.0.1:' + PORT);
