import XCTest

@testable import halochat_flutter

class RunnerTests: XCTestCase {

  func testRecognisesHaloChatPayload() {
    XCTAssertTrue(HalochatFlutterPlugin.isHaloChatPayload(["type": "halochat_message"]))
    XCTAssertFalse(HalochatFlutterPlugin.isHaloChatPayload(["type": "order"]))
    XCTAssertFalse(HalochatFlutterPlugin.isHaloChatPayload([:]))
  }

}
