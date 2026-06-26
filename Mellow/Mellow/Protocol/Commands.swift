import Foundation

// control plane (PROTOCOL.md §6). all multi-byte fields LE. written to cmd char (write-without-response)
enum RingCommand {

    // startup probe 08 03 00 00 00 (§6.1 step 1)
    static let timeOrIdReq: [UInt8] = [0x08, 0x03, 0x00, 0x00, 0x00]

    // sec_cfg pre / neg (§6.1 steps 3,5)
    static let secCfgPre: [UInt8] = [0x2f, 0x02, 0x01, 0x00]
    static let secCfgNeg: [UInt8] = [0x2f, 0x02, 0x01, 0x01]

    // request handshake nonce 2f 01 2b (§6.1 step 7)
    static let requestNonce: [UInt8] = [0x2f, 0x01, 0x2b]

    // submit handshake proof 2f 11 2d <proof:16> (§6.1 step 10)
    static func submitProof(_ proof: [UInt8]) -> [UInt8] {
        precondition(proof.count == 16)
        return [0x2f, 0x11, 0x2d] + proof
    }

    // subscribe enable/disable 16 01 0X (§6.6)
    static let subscribeEnable: [UInt8] = [0x16, 0x01, 0x02]
    static let subscribeDisable: [UInt8] = [0x16, 0x01, 0x00]

    // state_cmd 1c 01 bf, engage data plane (§6.1 step 13)
    static let stateCmd: [UInt8] = [0x1c, 0x01, 0xbf]

    // battery probe 0c 00 (§6.1 step 14)
    static let batteryReq: [UInt8] = [0x0c, 0x00]

    // capability dance reads/writes (§4.3, §6.1 step 15)
    static let capabilityDance: [[UInt8]] = [
        [0x2f, 0x02, 0x20, 0x02], [0x2f, 0x02, 0x20, 0x04], [0x2f, 0x02, 0x03, 0x01],
        [0x2f, 0x02, 0x20, 0x0b], [0x2f, 0x02, 0x20, 0x0d], [0x2f, 0x02, 0x20, 0x03],
        [0x2f, 0x02, 0x20, 0x0b], [0x2f, 0x02, 0x20, 0x10],
    ]

    // data_flush 28 01 00 (§6.5)
    static let dataFlush: [UInt8] = [0x28, 0x01, 0x00]

    // GetEvent 10 09 <ringTimestamp:4 LE> <max_events:1> <flags:4 LE> (§6.4)
    static func getEvent(cursor: UInt32, maxEvents: UInt8, flags: UInt32 = 0xFFFFFFFF) -> [UInt8] {
        var b: [UInt8] = [0x10, 0x09]
        b.append(UInt8(cursor & 0xff))
        b.append(UInt8((cursor >> 8) & 0xff))
        b.append(UInt8((cursor >> 16) & 0xff))
        b.append(UInt8((cursor >> 24) & 0xff))
        b.append(maxEvents)
        b.append(UInt8(flags & 0xff))
        b.append(UInt8((flags >> 8) & 0xff))
        b.append(UInt8((flags >> 16) & 0xff))
        b.append(UInt8((flags >> 24) & 0xff))
        return b
    }

    // time sync 12 09 <token> <counter:3 LE> 00 00 00 00 f6 (§6.3). counter = unix_s / 256
    static func timeSync(unixSeconds: Int, token: UInt8 = 0x01) -> [UInt8] {
        let counter = unixSeconds / 256
        return [0x12, 0x09, token,
                UInt8(counter & 0xff), UInt8((counter >> 8) & 0xff), UInt8((counter >> 16) & 0xff),
                0x00, 0x00, 0x00, 0x00, 0xf6]
    }

    // DHR burst trigger sequence (§6.7), force live high-rate HR sampling
    static let dhrBurst: [[UInt8]] = [
        [0x2f, 0x02, 0x20, 0x02],   // read DHR (capability check)
        [0x2f, 0x03, 0x22, 0x02, 0x03], // write DHR.byte_0 = 3 (burst)
        [0x2f, 0x03, 0x26, 0x02, 0x02], // write DHR.byte_2 = 2 (sub-mode)
    ]

    // MARK: - Live PPG / Daytime-HR streaming (§6.7, hr_live.py)

    // event subscribe 18 03 <cat> <flagLo> <flagHi>, sent once after handshake to open
    // the data categories live HR push needs. (cat, flag) pairs verbatim from proven Python flow
    static let liveFeatureCategories: [(cat: UInt8, flag: UInt16)] = [
        (0x14, 0x1000), (0x18, 0x1000), (0x28, 0x0900),
        (0x34, 0x0400), (0x04, 0x1000), (0x08, 0x1000),
    ]

    // 18 03 <cat> <flagLo> <flagHi> event-subscribe frame
    static func eventSubscribe(category: UInt8, flag: UInt16) -> [UInt8] {
        [0x18, 0x03, category, UInt8(flag & 0xff), UInt8(flag >> 8)]
    }

    // set feature mode 2f 03 22 <featureID> <mode>. DaytimeHR feature 0x02,
    // mode 0x03 = Requested-subscription. send ONCE to begin PPG push stream
    static func setFeatureMode(feature: UInt8, mode: UInt8) -> [UInt8] {
        [0x2f, 0x03, 0x22, feature, mode]
    }

    // set feature subscription 2f 03 26 <featureID> <subscription>. DaytimeHR
    // feature 0x02, subscription 0x02 = Latest. send ONCE, right after mode
    static func setFeatureSubscription(feature: UInt8, subscription: UInt8) -> [UInt8] {
        [0x2f, 0x03, 0x26, feature, subscription]
    }

    static let daytimeHRFeature: UInt8 = 0x02

    // two writes that begin live PPG push stream. set ONCE then leave ring
    // uninterrupted (re-sending repeatedly stalls the stream)
    static var activateDaytimeHR: [[UInt8]] {
        [setFeatureMode(feature: daytimeHRFeature, mode: 0x03),       // 2f 03 22 02 03
         setFeatureSubscription(feature: daytimeHRFeature, subscription: 0x02)] // 2f 03 26 02 02
    }

    // feature state read 2f 02 20 <featureID>, observe-only keep-alive poll while
    // streaming (does NOT re-trigger measurement)
    static func readFeatureState(feature: UInt8) -> [UInt8] {
        [0x2f, 0x02, 0x20, feature]
    }

    // MARK: - Workout / Exercise-HR streaming (RE'd from official strength-training capture)
    //
    // dense live-HR trigger during a logged workout is Exercise-HR feature (0x03)
    // in mode Requested (0x02), NOT DaytimeHR (0x02) and NOT 0x06. paired with two
    // Data-Collection enables and a repeated Get-Events poll. records come back as
    // normal inner records on notify char (0x80 green IBI, 0x60 IBI+amp, 0x46 temp,
    // 0x47 motion, 0x7e/0x7f steps), handled by existing decode path

    static let exerciseHRFeature: UInt8 = 0x03

    static let exerciseHRModeRequested: UInt8 = 0x02   // START
    static let exerciseHRModeOff: UInt8 = 0x00         // STOP

    // data collection 03 01 <arg> (opcode 0x03, len 0x01, arg byte).
    // arg 0x03 = Exercise HR, arg 0x0b = Real Steps
    static func dataCollection(_ arg: UInt8) -> [UInt8] { [0x03, 0x01, arg] }

    static let dataCollectionExerciseHR: UInt8 = 0x03
    static let dataCollectionRealSteps: UInt8 = 0x0b

    // workout get-events poll 10 09 <startTs:4 LE> ff ff ff ff ff (maxEvents 0xff,
    // flags 0xffffffff). official app repeats ~every 4 s to pull workout records
    static func getEvents(since: UInt32) -> [UInt8] {
        getEvent(cursor: since, maxEvents: 0xff, flags: 0xffffffff)
    }

    // START sequence for dense workout/Exercise-HR streaming, exact capture order:
    //   2f 03 22 03 02   set feature mode: Exercise-HR (0x03), Requested (0x02)
    //   03 01 03         data collection: Exercise HR
    //   03 01 0b         data collection: Real Steps
    //   16 01 02         subscribe enable
    //   18 03 18 00 10   event subscribe: category 0x18, flag 0x1000
    //   28 01 00         data flush
    static var activateWorkoutHR: [[UInt8]] {
        [setFeatureMode(feature: exerciseHRFeature, mode: exerciseHRModeRequested), // 2f 03 22 03 02
         dataCollection(dataCollectionExerciseHR),                                  // 03 01 03
         dataCollection(dataCollectionRealSteps),                                   // 03 01 0b
         subscribeEnable,                                                           // 16 01 02
         eventSubscribe(category: 0x18, flag: 0x1000),                              // 18 03 18 00 10
         dataFlush]                                                                 // 28 01 00
    }

    // STOP frame: set feature mode Exercise-HR (0x03) Off (0x00) = 2f 03 22 03 00
    static var stopWorkoutHR: [UInt8] {
        setFeatureMode(feature: exerciseHRFeature, mode: exerciseHRModeOff)
    }

    // MARK: - Provisioning (provision.py)

    // enrollment key-set 24 10 <auth_key:16>, writes our own auth_key into a
    // factory-reset ring (account-free provisioning). unused by live UI
    static func keySet(_ authKey: [UInt8]) -> [UInt8] {
        precondition(authKey.count == 16)
        return [0x24, 0x10] + authKey
    }

    // MARK: - Onboarding + Live HR (captured from official Oura app, 2026-06-16)
    //
    // right after key-set + handshake, official app runs a feature-enable sequence
    // that flips ring into "fully onboarded" (tracks HR/sleep), then triggers Live
    // HR with a single 0x06 write. live data streams back as 0x33 records (6 int16
    // PPG samples each) plus occasional 0x80 green-IBI records. verified on our key

    // post-key-set onboarding sequence official app sends (handle 0x15), in capture
    // order. enables full sensor feature set (0x02 DaytimeHR, 0x0b RealSteps,
    // 0x03 ExerciseHR, 0x04 SpO2, 0x0d CVA/rawPPG, 0x12)
    static let onboardingSequence: [[UInt8]] = [
        [0x2f, 0x02, 0x03, 0x01],         // sec/config step 0x03 (was missing)
        [0x1c, 0x01, 0xff],               // state_cmd (ff, not bf)
        [0x18, 0x03, 0x18, 0x00, 0x10],   // event_subscribe cat 0x18
        [0x08, 0x03, 0x00, 0x00, 0x00],   // time_or_id_req
        [0x2f, 0x03, 0x22, 0x02, 0x03],   // set feature 0x02 mode 0x03
        [0x2f, 0x03, 0x22, 0x0b, 0x01],   // set feature 0x0b mode 0x01
        [0x2f, 0x03, 0x26, 0x02, 0x02],   // feature 0x02 subscription Latest
        [0x2f, 0x03, 0x22, 0x03, 0x01],   // set feature 0x03 mode 0x01
        [0x16, 0x01, 0x02],               // subscribe enable
        [0x2f, 0x03, 0x22, 0x12, 0x01],   // set feature 0x12 mode 0x01
        [0x2f, 0x03, 0x22, 0x04, 0x01],   // set feature 0x04 (SpO2) mode 0x01
        [0x28, 0x01, 0x00],               // data_flush
        [0x2f, 0x03, 0x22, 0x0d, 0x01],   // set feature 0x0d (raw PPG) mode 0x01
    ]

    // measure HR trigger 06 04 20000000 (0x06 Set Realtime Measurements). fires
    // dense live PPG stream (0x33 records). re-send to keep/refresh measurement
    static let measureHeartRate: [UInt8] = [0x06, 0x04, 0x20, 0x00, 0x00, 0x00]

    // soft reset 0e 01 ff (§6.8), triggers ring reboot 22-35 s later
    static let softReset: [UInt8] = [0x0e, 0x01, 0xff]

    // factory reset 1a 00 (opcode 0x1A, len 0x00, no payload). ring replies
    // 1b <status:u16 LE> (0 = ok), wipes stored auth_key, reboots blank so official
    // app can reclaim it. see RingSession.factoryReset()
    static let factoryReset: [UInt8] = [0x1a, 0x00]
}
