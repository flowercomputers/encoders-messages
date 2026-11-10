// Makes a synthetic database with the parts of the chat.db schema the app
// reads, for testing and benchmarking without touching real messages.
//
//   swift scripts/make_test_db.swift test.db 500000
//
// Like a modern chat.db, most rows have a NULL `text` and a real NSArchiver
// typedstream in `attributedBody`.

import Foundation
import SQLite3

let args = CommandLine.arguments
guard args.count == 3, let total = Int(args[2]) else {
    print("usage: make_test_db.swift <path> <message count>")
    exit(1)
}
try? FileManager.default.removeItem(atPath: args[1])

var db: OpaquePointer?
sqlite3_open(args[1], &db)
sqlite3_exec(db, """
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, style INTEGER);
    CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, PRIMARY KEY (chat_id, message_id));
    CREATE INDEX chat_message_join_idx_message_id_only ON chat_message_join(message_id);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB,
        date INTEGER, is_from_me INTEGER, handle_id INTEGER, associated_message_type INTEGER DEFAULT 0);
    BEGIN;
    """, nil, nil, nil)

let people = 40
for i in 1...people {
    sqlite3_exec(db, "INSERT INTO handle VALUES (\(i), '+1555000\(1000 + i)')", nil, nil, nil)
    sqlite3_exec(db, "INSERT INTO chat VALUES (\(i), 'iMessage;-;+1555000\(1000 + i)', '+1555000\(1000 + i)', '', 45)", nil, nil, nil)
    sqlite3_exec(db, "INSERT INTO chat_handle_join VALUES (\(i), \(i))", nil, nil, nil)
}
sqlite3_exec(db, "INSERT INTO chat VALUES (\(people + 1), 'iMessage;+;chat1', 'chat1', 'Lake House Weekend', 43)", nil, nil, nil)

let openers = ["", "", "", "ok so ", "honestly ", "btw ", "wait ", "lol ", "hey ", "update: "]
let closers = ["", "", "", " lol", " 😂", "!!", " let me know", " if that works", " ❤️", "?"]
let bodies = [
    "want to grab dinner at that new ramen place on friday", "the pasta you made last night was incredible",
    "can you pick up oat milk and eggs on the way home", "I'm thinking tacos tonight, the truck by the park",
    "our flight lands at 6:40, terminal B", "I booked the cabin for the long weekend", "the train to Lyon was delayed two hours",
    "did you renew your passport yet", "the landlord is raising rent by 200 next month", "the dishwasher is leaking again",
    "I signed the lease, we move in on the first", "the plumber can come thursday morning",
    "my boss wants the deck finished before the offsite", "I got the job offer, they matched the salary",
    "standup moved to 10, can you cover for me", "the deploy broke prod and I was up until 3",
    "the vet says the dog needs to lose a few pounds", "the cat knocked the plant off the shelf again",
    "we adopted a puppy, her name is Olive", "I have a dentist appointment at 2", "my knee still hurts from the run on sunday",
    "the doctor said the results came back normal", "I think I'm coming down with a cold",
    "can you venmo me for the concert tickets", "I owe you 40 for the groceries", "the car repair is going to cost a fortune",
    "have you watched the new season yet, no spoilers", "that movie made me cry on the plane",
    "this album has been on repeat all week", "the band is playing at the old theater in march",
    "mom's birthday is next weekend, what should we get her", "grandpa is out of the hospital and doing better",
    "my sister just had the baby, a girl", "are you coming home for thanksgiving",
    "I miss you, when can I see you again", "I'm sorry about what I said earlier", "so proud of you, you earned it",
    "the wifi password is on the fridge", "my phone screen cracked again", "can you send me the photos from the hike",
    "it's supposed to snow eight inches tonight", "the sunset at the beach was unreal", "running late, stuck in traffic on the bridge",
    "I finished the marathon in under four hours", "the kids have soccer practice until five",
    "her recital is tuesday at the school auditorium", "I finally finished that book you lent me",
    "the garden tomatoes are finally ripe", "the election results are stressing me out", "happy anniversary, ten years",
]

let insert = "INSERT INTO message (ROWID, guid, text, attributedBody, date, is_from_me, handle_id, associated_message_type) VALUES (?,?,?,?,?,?,?,?)"
var stmt: OpaquePointer?
sqlite3_prepare_v2(db, insert, -1, &stmt, nil)
var join: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO chat_message_join VALUES (?,?)", -1, &join, nil)
let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

var rng = SystemRandomNumberGenerator()
let now = Int64(Date().timeIntervalSinceReferenceDate * 1e9)
for row in 1...total {
    var body = openers.randomElement(using: &rng)! + bodies.randomElement(using: &rng)! + closers.randomElement(using: &rng)!
    if row % 5000 == 0 { body += String(repeating: " and another thing about that,", count: 20) }  // 2-byte length
    let handle = Int32.random(in: 1...Int32(people), using: &rng)
    let tapback = row % 11 == 0

    sqlite3_bind_int64(stmt, 1, Int64(row))
    sqlite3_bind_text(stmt, 2, UUID().uuidString, -1, transient)
    switch row % 4 {
    case 0:  // legacy row: plain text column
        sqlite3_bind_text(stmt, 3, body, -1, transient)
        sqlite3_bind_null(stmt, 4)
    case 1:  // mutable attributed string
        let data = NSArchiver.archivedData(withRootObject: NSMutableAttributedString(string: body))
        sqlite3_bind_null(stmt, 3)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
    default:
        let attributed = NSAttributedString(string: body, attributes: [NSAttributedString.Key("__kIMMessagePartAttributeName"): 0])
        let data = NSArchiver.archivedData(withRootObject: attributed)
        sqlite3_bind_null(stmt, 3)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), transient) }
    }
    sqlite3_bind_int64(stmt, 5, now - Int64(total - row) * 60_000_000_000)
    sqlite3_bind_int(stmt, 6, row % 3 == 0 ? 1 : 0)
    sqlite3_bind_int(stmt, 7, handle)
    sqlite3_bind_int(stmt, 8, tapback ? 2000 : 0)
    sqlite3_step(stmt)
    sqlite3_reset(stmt)

    sqlite3_bind_int(join, 1, row % 17 == 0 ? Int32(people + 1) : handle)
    sqlite3_bind_int64(join, 2, Int64(row))
    sqlite3_step(join)
    sqlite3_reset(join)
}
sqlite3_exec(db, "COMMIT", nil, nil, nil)
sqlite3_close(db)
print("wrote \(total) messages to \(args[1])")
