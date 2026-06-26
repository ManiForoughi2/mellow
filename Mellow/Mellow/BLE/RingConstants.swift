import CoreBluetooth

// GATT identifiers (PROTOCOL.md 1.1). service UUID is stable across firmware revs
// and the only reliable identifier under LE Privacy (public MAC rotates as RPA)
enum RingGATT {
    static let serviceUUID = CBUUID(string: "98ed0001-a541-11e4-b6a0-0002a5d5c51b")
    // notify char (handle 0x0012, ATT op 0x1B)
    static let notifyUUID  = CBUUID(string: "98ed0003-a541-11e4-b6a0-0002a5d5c51b")
    // cmd char UUID not published by spec (only "resolves to handle 0x0015"). select
    // by property (write-without-response) not this guessed UUID. conventional
    // 98ed0002 in observed rings but never relied on
    static let likelyCmdUUID = CBUUID(string: "98ed0002-a541-11e4-b6a0-0002a5d5c51b")

    // ring's preferred ATT MTU (1.2). iOS negotiates automatically, cant force it,
    // but typically gets >=185 covering all record types except longest which
    // fragment cleanly
    static let preferredMTU = 247
}
