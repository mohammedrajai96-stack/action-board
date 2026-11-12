// WhatsApp Desk bridge
// Links personal WhatsApp numbers as "linked devices" (like WhatsApp Web),
// keeps their chats in a local database, and offers a small local web API
// (127.0.0.1 only) that the desktop widget reads from.
package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/skip2/go-qrcode"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

const listenAddr = "127.0.0.1:47321"
const maxAccounts = 5

type Account struct {
	Client  *whatsmeow.Client
	TempID  string
	QR      string
	Pairing bool
	Err     string
	mu      sync.Mutex
}

func (a *Account) ID() string {
	if a.Client != nil && a.Client.Store != nil && a.Client.Store.ID != nil {
		return a.Client.Store.ID.User
	}
	return a.TempID
}

var (
	ctx       = context.Background()
	container *sqlstore.Container
	msgDB     *sql.DB
	accounts  []*Account
	accMu     sync.Mutex
	token     string
	dataDir   string
	logFile   *os.File
	groupMu   sync.Mutex
	groupName = map[string]string{}
	tempSeq   = 0
)

func logf(format string, args ...any) {
	if logFile != nil {
		fmt.Fprintf(logFile, time.Now().Format("2006-01-02 15:04:05")+"  "+format+"\n", args...)
	}
}

func main() {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		appData = "."
	}
	dataDir = filepath.Join(appData, "WhatsAppDesk")
	_ = os.MkdirAll(dataDir, 0o700)

	logFile, _ = os.OpenFile(filepath.Join(dataDir, "bridge.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if logFile != nil {
		os.Stdout = logFile
		os.Stderr = logFile
	}

	// only one copy may run
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		logf("Another copy is already running (%v)", err)
		return
	}

	token = loadOrCreateToken()
	store.DeviceProps.Os = proto.String("WhatsApp Desk (Windows)")

	waLogger := waLog.Stdout("WA", "WARN", false)

	db, err := sql.Open("sqlite", "file:"+filepath.ToSlash(filepath.Join(dataDir, "session.db"))+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)")
	if err != nil {
		logf("open session db: %v", err)
		return
	}
	container = sqlstore.NewWithDB(db, "sqlite3", waLogger)
	if err := container.Upgrade(ctx); err != nil {
		logf("upgrade session db: %v", err)
		return
	}

	msgDB, err = sql.Open("sqlite", "file:"+filepath.ToSlash(filepath.Join(dataDir, "messages.db"))+"?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)")
	if err != nil {
		logf("open messages db: %v", err)
		return
	}
	msgDB.SetMaxOpenConns(1)
	initMsgDB()

	devices, err := container.GetAllDevices(ctx)
	if err != nil {
		logf("load devices: %v", err)
	}
	for _, dev := range devices {
		acct := &Account{}
		acct.Client = whatsmeow.NewClient(dev, waLog.Stdout("Client", "WARN", false))
		attachHandler(acct)
		accMu.Lock()
		accounts = append(accounts, acct)
		accMu.Unlock()
		go func(a *Account) {
			if err := a.Client.Connect(); err != nil {
				a.mu.Lock()
				a.Err = err.Error()
				a.mu.Unlock()
				logf("connect %s: %v", a.ID(), err)
			}
		}(acct)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", auth(handleStatus))
	mux.HandleFunc("/api/accounts/add", auth(handleAdd))
	mux.HandleFunc("/api/accounts/qr", auth(handleQR))
	mux.HandleFunc("/api/accounts/remove", auth(handleRemove))
	mux.HandleFunc("/api/chats", auth(handleChats))
	mux.HandleFunc("/api/messages", auth(handleMessages))
	mux.HandleFunc("/api/read", auth(handleRead))
	mux.HandleFunc("/api/send", auth(handleSend))
	mux.HandleFunc("/api/quit", auth(handleQuit))
	logf("WhatsApp Desk bridge started with %d linked number(s)", len(devices))
	_ = http.Serve(ln, mux)
}

func loadOrCreateToken() string {
	p := filepath.Join(dataDir, "token.txt")
	if b, err := os.ReadFile(p); err == nil && len(strings.TrimSpace(string(b))) >= 16 {
		return strings.TrimSpace(string(b))
	}
	buf := make([]byte, 24)
	_, _ = rand.Read(buf)
	t := hex.EncodeToString(buf)
	_ = os.WriteFile(p, []byte(t), 0o600)
	return t
}

// ---------------------------------------------------------------------------
// message store
// ---------------------------------------------------------------------------

func initMsgDB() {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS messages (
			account TEXT NOT NULL, chat TEXT NOT NULL, id TEXT NOT NULL,
			sender TEXT, sender_name TEXT, from_me INTEGER NOT NULL DEFAULT 0,
			ts INTEGER NOT NULL, body TEXT,
			PRIMARY KEY (account, chat, id))`,
		`CREATE INDEX IF NOT EXISTS idx_msg_chat_ts ON messages(account, chat, ts)`,
		`CREATE TABLE IF NOT EXISTS chats (
			account TEXT NOT NULL, chat TEXT NOT NULL, name TEXT,
			last_ts INTEGER NOT NULL DEFAULT 0, unread INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (account, chat))`,
	}
	for _, s := range stmts {
		if _, err := msgDB.Exec(s); err != nil {
			logf("init db: %v", err)
		}
	}
}

func describe(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	cap := func(c string) string {
		if c != "" {
			return " " + c
		}
		return ""
	}
	switch {
	case m.GetConversation() != "":
		return m.GetConversation()
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetText()
	case m.GetImageMessage() != nil:
		return "📷 Photo" + cap(m.GetImageMessage().GetCaption())
	case m.GetVideoMessage() != nil:
		return "🎥 Video" + cap(m.GetVideoMessage().GetCaption())
	case m.GetDocumentMessage() != nil:
		name := m.GetDocumentMessage().GetFileName()
		if name == "" {
			name = "Document"
		}
		return "📄 " + name + cap(m.GetDocumentMessage().GetCaption())
	case m.GetDocumentWithCaptionMessage() != nil:
		return describe(m.GetDocumentWithCaptionMessage().GetMessage())
	case m.GetAudioMessage() != nil:
		if m.GetAudioMessage().GetPTT() {
			return "🎤 Voice message"
		}
		return "🎵 Audio"
	case m.GetStickerMessage() != nil:
		return "Sticker"
	case m.GetLocationMessage() != nil:
		return "📍 Location"
	case m.GetLiveLocationMessage() != nil:
		return "📍 Live location"
	case m.GetContactMessage() != nil:
		return "👤 Contact: " + m.GetContactMessage().GetDisplayName()
	case m.GetContactsArrayMessage() != nil:
		return "👤 Contacts"
	case m.GetPollCreationMessage() != nil:
		return "📊 Poll: " + m.GetPollCreationMessage().GetName()
	case m.GetPollCreationMessageV3() != nil:
		return "📊 Poll: " + m.GetPollCreationMessageV3().GetName()
	}
	return ""
}

func contactName(c *whatsmeow.Client, jid types.JID) string {
	if c == nil || c.Store == nil || c.Store.Contacts == nil {
		return ""
	}
	info, err := c.Store.Contacts.GetContact(ctx, jid.ToNonAD())
	if err != nil || !info.Found {
		return ""
	}
	for _, n := range []string{info.FullName, info.FirstName, info.BusinessName, info.PushName} {
		if strings.TrimSpace(n) != "" {
			return n
		}
	}
	return ""
}

func groupTitle(c *whatsmeow.Client, jid types.JID) string {
	key := jid.String()
	groupMu.Lock()
	n, ok := groupName[key]
	groupMu.Unlock()
	if ok {
		return n
	}
	info, err := c.GetGroupInfo(ctx, jid)
	if err != nil || info == nil {
		return ""
	}
	groupMu.Lock()
	groupName[key] = info.Name
	groupMu.Unlock()
	return info.Name
}

func saveMessage(acct *Account, evt *events.Message, countUnread bool, chatNameHint string) {
	info := evt.Info
	if info.Chat.Server == types.BroadcastServer || info.Chat.User == "status" {
		return
	}
	m := evt.Message
	if m.GetReactionMessage() != nil || m.GetProtocolMessage() != nil {
		return
	}
	body := describe(m)
	if body == "" {
		return
	}
	accID := acct.ID()
	chat := info.Chat.ToNonAD().String()
	ts := info.Timestamp.UnixMilli()

	senderName := ""
	if !info.IsFromMe {
		senderName = contactName(acct.Client, info.Sender)
		if senderName == "" {
			senderName = info.PushName
		}
	}

	res, err := msgDB.Exec(`INSERT OR IGNORE INTO messages (account, chat, id, sender, sender_name, from_me, ts, body)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		accID, chat, info.ID, info.Sender.ToNonAD().String(), senderName, boolInt(info.IsFromMe), ts, body)
	if err != nil {
		logf("save message: %v", err)
		return
	}
	added, _ := res.RowsAffected()

	name := chatNameHint
	if isMasked(name) {
		name = ""
	}
	if name == "" {
		if info.Chat.Server == types.GroupServer {
			name = groupTitle(acct.Client, info.Chat)
		} else {
			name = contactName(acct.Client, info.Chat)
			if name == "" && !info.IsFromMe {
				name = info.PushName
			}
		}
	}
	inc := 0
	if countUnread && added > 0 && !info.IsFromMe {
		inc = 1
	}
	_, err = msgDB.Exec(`INSERT INTO chats (account, chat, name, last_ts, unread) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(account, chat) DO UPDATE SET
			name = COALESCE(NULLIF(excluded.name, ''), chats.name),
			last_ts = MAX(chats.last_ts, excluded.last_ts),
			unread = CASE WHEN ? THEN 0 ELSE chats.unread + excluded.unread END`,
		accID, chat, name, ts, inc, boolInt(info.IsFromMe && countUnread))
	if err != nil {
		logf("save chat: %v", err)
	}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func attachHandler(acct *Account) {
	acct.Client.AddEventHandler(func(raw any) {
		defer func() {
			if r := recover(); r != nil {
				logf("event handler panic: %v", r)
			}
		}()
		switch evt := raw.(type) {
		case *events.Message:
			saveMessage(acct, evt, true, "")
		case *events.HistorySync:
			c := acct.Client
			for _, conv := range evt.Data.GetConversations() {
				chatJID, err := types.ParseJID(conv.GetID())
				if err != nil {
					continue
				}
				hint := conv.GetName()
				if hint == "" {
					hint = conv.GetDisplayName()
				}
				for _, hm := range conv.GetMessages() {
					parsed, err := c.ParseWebMessage(chatJID, hm.GetMessage())
					if err != nil || parsed == nil {
						continue
					}
					saveMessage(acct, parsed, false, hint)
				}
				if conv.GetUnreadCount() > 0 {
					_, _ = msgDB.Exec(`UPDATE chats SET unread = ? WHERE account = ? AND chat = ?`,
						conv.GetUnreadCount(), acct.ID(), chatJID.ToNonAD().String())
				}
			}
		case *events.PairSuccess:
			acct.mu.Lock()
			acct.Pairing = false
			acct.QR = ""
			acct.Err = ""
			acct.mu.Unlock()
			logf("linked %s", evt.ID.User)
		case *events.LoggedOut:
			acct.mu.Lock()
			acct.Err = "This number was unlinked from the phone. Remove it and add it again."
			acct.mu.Unlock()
		case *events.Contact, *events.PushName, *events.AppStateSyncComplete:
			nameCacheMu.Lock()
			nameCache = map[string]string{}
			nameCacheMu.Unlock()
		case *events.Connected:
			acct.mu.Lock()
			acct.Err = ""
			acct.mu.Unlock()
		}
	})
}

// ---------------------------------------------------------------------------
// web API
// ---------------------------------------------------------------------------

func auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Token") != token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		h(w, r)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func findAccount(id string) *Account {
	accMu.Lock()
	defer accMu.Unlock()
	for _, a := range accounts {
		if a.ID() == id {
			return a
		}
	}
	return nil
}

type accountInfo struct {
	ID        string `json:"id"`
	Phone     string `json:"phone"`
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
	LoggedIn  bool   `json:"logged_in"`
	Pairing   bool   `json:"pairing"`
	HasQR     bool   `json:"has_qr"`
	Error     string `json:"error"`
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	accMu.Lock()
	list := append([]*Account(nil), accounts...)
	accMu.Unlock()
	out := []accountInfo{}
	for _, a := range list {
		a.mu.Lock()
		ai := accountInfo{ID: a.ID(), Pairing: a.Pairing, HasQR: a.QR != "", Error: a.Err}
		a.mu.Unlock()
		if a.Client != nil {
			ai.Connected = a.Client.IsConnected()
			ai.LoggedIn = a.Client.IsLoggedIn()
			if a.Client.Store != nil && a.Client.Store.ID != nil {
				ai.Phone = "+" + a.Client.Store.ID.User
				ai.Name = a.Client.Store.PushName
			}
		}
		out = append(out, ai)
	}
	writeJSON(w, map[string]any{"accounts": out})
}

func handleAdd(w http.ResponseWriter, r *http.Request) {
	accMu.Lock()
	if len(accounts) >= maxAccounts {
		accMu.Unlock()
		http.Error(w, "too many numbers", http.StatusBadRequest)
		return
	}
	tempSeq++
	acct := &Account{TempID: "new-" + strconv.Itoa(tempSeq), Pairing: true}
	accounts = append(accounts, acct)
	accMu.Unlock()

	dev := container.NewDevice()
	acct.Client = whatsmeow.NewClient(dev, waLog.Stdout("Client", "WARN", false))
	attachHandler(acct)
	qrChan, err := acct.Client.GetQRChannel(ctx)
	if err != nil {
		acct.Err = err.Error()
		writeJSON(w, map[string]any{"id": acct.TempID, "error": err.Error()})
		return
	}
	go func() {
		for item := range qrChan {
			acct.mu.Lock()
			switch item.Event {
			case "code":
				acct.QR = item.Code
			case "success":
				acct.QR = ""
				acct.Pairing = false
			case "timeout":
				acct.QR = ""
				acct.Err = "The QR code expired. Close this window and try again."
			default:
				if item.Error != nil {
					acct.Err = item.Error.Error()
				}
			}
			acct.mu.Unlock()
		}
	}()
	if err := acct.Client.Connect(); err != nil {
		acct.Err = err.Error()
	}
	writeJSON(w, map[string]any{"id": acct.TempID})
}

func handleQR(w http.ResponseWriter, r *http.Request) {
	a := findAccount(r.URL.Query().Get("id"))
	if a == nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	a.mu.Lock()
	code := a.QR
	a.mu.Unlock()
	if code == "" {
		http.Error(w, "no qr", http.StatusNotFound)
		return
	}
	png, err := qrcode.Encode(code, qrcode.Medium, 320)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(png)
}

func handleRemove(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	a := findAccount(id)
	if a == nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if a.Client != nil {
		if a.Client.IsLoggedIn() {
			if err := a.Client.Logout(ctx); err != nil {
				logf("logout %s: %v", id, err)
			}
		}
		a.Client.Disconnect()
		if a.Client.Store != nil && a.Client.Store.ID != nil {
			_ = a.Client.Store.Delete(ctx)
		}
	}
	accMu.Lock()
	for i, x := range accounts {
		if x == a {
			accounts = append(accounts[:i], accounts[i+1:]...)
			break
		}
	}
	accMu.Unlock()
	_, _ = msgDB.Exec(`DELETE FROM messages WHERE account = ?`, id)
	_, _ = msgDB.Exec(`DELETE FROM chats WHERE account = ?`, id)
	writeJSON(w, map[string]any{"ok": true})
}

type chatRow struct {
	Account    string `json:"account"`
	Chat       string `json:"chat"`
	Name       string `json:"name"`
	IsGroup    bool   `json:"is_group"`
	LastTs     int64  `json:"last_ts"`
	LastText   string `json:"last_text"`
	LastFromMe bool   `json:"last_from_me"`
	LastSender string `json:"last_sender"`
	Unread     int    `json:"unread"`
}

// A name WhatsApp sent with dots/asterisks hiding digits is not a real name.
func isMasked(name string) bool {
	return strings.ContainsAny(name, "•·∙*●")
}

var (
	nameCacheMu sync.Mutex
	nameCache   = map[string]string{}
)

// resolvePerson turns a chat/sender address (phone-based or WhatsApp's hidden
// "lid" id) into the best available name: saved contact name, then their own
// WhatsApp name, then their phone number.
func resolvePerson(accID, addr string) string {
	key := accID + "|" + addr
	nameCacheMu.Lock()
	if n, ok := nameCache[key]; ok {
		nameCacheMu.Unlock()
		return n
	}
	nameCacheMu.Unlock()

	jid, err := types.ParseJID(addr)
	if err != nil {
		return ""
	}
	a := findAccount(accID)
	name := ""
	if a != nil && a.Client != nil && a.Client.Store != nil {
		c := a.Client
		pn := jid
		if jid.Server == types.HiddenUserServer && c.Store.LIDs != nil {
			if p, err := c.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !p.IsEmpty() {
				pn = p
			}
		}
		name = contactName(c, pn)
		if name == "" && pn != jid {
			name = contactName(c, jid)
		}
		if name == "" && pn.Server == types.DefaultUserServer {
			name = "+" + pn.User
		}
	}
	if name == "" && jid.Server == types.DefaultUserServer {
		name = "+" + jid.User
	}
	if name != "" {
		nameCacheMu.Lock()
		nameCache[key] = name
		nameCacheMu.Unlock()
	}
	return name
}

func displayChatName(accID, name, chat string) string {
	jid, err := types.ParseJID(chat)
	if err == nil && jid.Server == types.GroupServer {
		if strings.TrimSpace(name) != "" {
			return name
		}
		if a := findAccount(accID); a != nil && a.Client != nil {
			if g := groupTitle(a.Client, jid); g != "" {
				return g
			}
		}
		return "Group"
	}
	if strings.TrimSpace(name) != "" && !isMasked(name) && !strings.HasPrefix(name, "+") {
		return name
	}
	if n := resolvePerson(accID, chat); n != "" {
		// a real contact name beats a bare number we may have stored earlier
		if !strings.HasPrefix(n, "+") || strings.TrimSpace(name) == "" || isMasked(name) {
			return n
		}
	}
	if strings.TrimSpace(name) != "" && !isMasked(name) {
		return name
	}
	if strings.TrimSpace(name) != "" {
		return name
	}
	return "Unknown contact"
}

func handleChats(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 300 {
		limit = 80
	}
	rows, err := msgDB.Query(`
		SELECT c.account, c.chat, COALESCE(c.name, ''), c.last_ts, c.unread,
		       COALESCE(m.body, ''), COALESCE(m.from_me, 0), COALESCE(m.sender_name, ''), COALESCE(m.sender, '')
		  FROM chats c
		  LEFT JOIN messages m ON m.rowid = (
		       SELECT rowid FROM messages x WHERE x.account = c.account AND x.chat = c.chat ORDER BY ts DESC LIMIT 1)
		 ORDER BY c.last_ts DESC LIMIT ?`, limit)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	out := []chatRow{}
	for rows.Next() {
		var c chatRow
		var fromMe int
		var senderAddr string
		if err := rows.Scan(&c.Account, &c.Chat, &c.Name, &c.LastTs, &c.Unread, &c.LastText, &fromMe, &c.LastSender, &senderAddr); err != nil {
			continue
		}
		c.LastFromMe = fromMe == 1
		c.IsGroup = strings.HasSuffix(c.Chat, "@g.us")
		c.Name = displayChatName(c.Account, c.Name, c.Chat)
		if c.IsGroup && !c.LastFromMe && senderAddr != "" && (c.LastSender == "" || isMasked(c.LastSender)) {
			if n := resolvePerson(c.Account, senderAddr); n != "" {
				c.LastSender = n
			}
		}
		out = append(out, c)
	}
	writeJSON(w, map[string]any{"chats": out})
}

type msgRow struct {
	ID         string `json:"id"`
	FromMe     bool   `json:"from_me"`
	SenderName string `json:"sender_name"`
	Ts         int64  `json:"ts"`
	Body       string `json:"body"`
}

func handleMessages(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 80
	}
	accID := q.Get("account")
	rows, err := msgDB.Query(`SELECT id, from_me, COALESCE(sender_name, ''), ts, COALESCE(body, ''), COALESCE(sender, '')
		FROM messages WHERE account = ? AND chat = ? ORDER BY ts DESC LIMIT ?`, q.Get("account"), q.Get("chat"), limit)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()
	out := []msgRow{}
	for rows.Next() {
		var m msgRow
		var fromMe int
		var senderAddr string
		if err := rows.Scan(&m.ID, &fromMe, &m.SenderName, &m.Ts, &m.Body, &senderAddr); err != nil {
			continue
		}
		m.FromMe = fromMe == 1
		if !m.FromMe && senderAddr != "" {
			if n := resolvePerson(accID, senderAddr); n != "" && (m.SenderName == "" || isMasked(m.SenderName) || !strings.HasPrefix(n, "+")) {
				m.SenderName = n
			}
		}
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Ts < out[j].Ts })
	writeJSON(w, map[string]any{"messages": out})
}

type chatRef struct {
	Account string `json:"account"`
	Chat    string `json:"chat"`
	Text    string `json:"text"`
}

func readBody(w http.ResponseWriter, r *http.Request) (chatRef, error) {
	var c chatRef
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&c)
	return c, err
}

func handleRead(w http.ResponseWriter, r *http.Request) {
	c, err := readBody(w, r)
	if err != nil {
		http.Error(w, "bad request", 400)
		return
	}
	_, _ = msgDB.Exec(`UPDATE chats SET unread = 0 WHERE account = ? AND chat = ?`, c.Account, c.Chat)
	writeJSON(w, map[string]any{"ok": true})
}

func handleSend(w http.ResponseWriter, r *http.Request) {
	c, err := readBody(w, r)
	if err != nil || strings.TrimSpace(c.Text) == "" {
		http.Error(w, "bad request", 400)
		return
	}
	a := findAccount(c.Account)
	if a == nil || a.Client == nil || !a.Client.IsLoggedIn() {
		writeJSON(w, map[string]any{"ok": false, "error": "That number is not connected right now."})
		return
	}
	to, err := types.ParseJID(c.Chat)
	if err != nil {
		writeJSON(w, map[string]any{"ok": false, "error": "Bad chat address."})
		return
	}
	resp, err := a.Client.SendMessage(ctx, to, &waE2E.Message{Conversation: proto.String(c.Text)})
	if err != nil {
		writeJSON(w, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	ts := resp.Timestamp
	if ts.IsZero() {
		ts = time.Now()
	}
	_, _ = msgDB.Exec(`INSERT OR IGNORE INTO messages (account, chat, id, sender, sender_name, from_me, ts, body)
		VALUES (?, ?, ?, '', '', 1, ?, ?)`, c.Account, to.ToNonAD().String(), resp.ID, ts.UnixMilli(), c.Text)
	_, _ = msgDB.Exec(`UPDATE chats SET last_ts = MAX(last_ts, ?), unread = 0 WHERE account = ? AND chat = ?`,
		ts.UnixMilli(), c.Account, to.ToNonAD().String())
	writeJSON(w, map[string]any{"ok": true})
}

func handleQuit(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"ok": true})
	go func() {
		time.Sleep(300 * time.Millisecond)
		accMu.Lock()
		for _, a := range accounts {
			if a.Client != nil {
				a.Client.Disconnect()
			}
		}
		accMu.Unlock()
		os.Exit(0)
	}()
}

