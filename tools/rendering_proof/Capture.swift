import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import CoreImage

struct Component {
  var color:Int;var x:Int;var y:Int;var right:Int;var bottom:Int
  var width:Int { right-x };var height:Int { bottom-y+1 }
  var json:[Int] { [x,y,width,height] }
}

enum MarkerOracle {
  static var cellWidth = 16
  static var cellHeight = 38
  static func color(_ b:UInt8,_ g:UInt8,_ r:UInt8) -> Int? {
    if r>190 && g<70 && b>190 { return 0 }
    if r<70 && g>190 && b<70 { return 1 }
    if r<70 && g>190 && b>190 { return 2 }
    return nil
  }
  static func evaluate(_ components:[Component], contentScale:Double, width:Int,height:Int) -> [[String:Any]] {
    (0..<3).map { pane in
      // Pane 1 occupies the right half; exclude only the tiny native green
      // control in the top-left chrome, not small/distorted content markers.
      let candidates=components.filter{$0.color==pane && !(pane==1 && $0.x<140 && $0.y<70 && $0.width<30 && $0.height<30)}
      var row:[String:Any]=["pane":pane,"metal":candidates.map{$0.json},"expected_wh":[6*cellWidth,2*cellHeight],"pane_local_offset_verified":false]
      func result(_ status:String,_ reason:String)->[String:Any] {row["result"]=status;row["reason"]=reason;return row}
      guard contentScale == 1 else {return result("inconclusive","capture_scaled")}
      guard candidates.count==1 else {return result("inconclusive","marker_missing_or_ambiguous")}
      let m=candidates[0]
      guard m.x>0 && m.y>0 && m.right<width && m.bottom+1<height else {return result("inconclusive","marker_clipped")}
      row["delta_wh"]=[m.width-6*cellWidth,m.height-2*cellHeight]
      guard abs(m.width-6*cellWidth)<=1 && abs(m.height-2*cellHeight)<=1 else {return result("failure","absolute_dimensions")}
      return result("correct","absolute_dimensions_only")
    }
  }
  static func selfTest() {
    let marker=Component(color:0,x:40,y:140,right:40+6*cellWidth,bottom:140+2*cellHeight-1)
    func status(_ c:[Component],_ scale:Double=1)->String {evaluate(c,contentScale:scale,width:2600,height:1800)[0]["result"] as! String}
    precondition(status([marker])=="correct")
    var stretched=marker;stretched.right+=6*cellWidth
    precondition(status([stretched])=="failure")
    stretched.bottom+=2*cellHeight
    precondition(status([stretched])=="failure")
    stretched=marker;stretched.right=stretched.x+3;stretched.bottom=stretched.y+1
    precondition(status([stretched])=="failure")
    precondition(status([])=="inconclusive")
    precondition(status([marker],0.5)=="inconclusive")
    precondition(status([marker,marker])=="inconclusive")
    var clipped=marker;clipped.x=0
    precondition(status([clipped])=="inconclusive")
    print("PASS absolute marker oracle: horizontal/uniform/collapsed scaling red; missing, duplicate, clipped and capture-scaled inconclusive")
  }
}

final class RecordingState {
  private let lock = NSLock()
  private var finished = false
  private var failure: String?
  func didFinish() { lock.lock(); defer { lock.unlock() }; finished = true }
  func didFail(_ message: String) { lock.lock(); defer { lock.unlock() }; failure = message }
  var snapshot: (finished: Bool, failure: String?) {
    lock.lock(); defer { lock.unlock() }; return (finished && failure == nil, failure)
  }
  static func selfTest() {
    let pending = RecordingState()
    precondition(!pending.snapshot.finished)
    pending.didFinish(); precondition(pending.snapshot.finished)
    let failed = RecordingState()
    failed.didFail("test failure"); precondition(!failed.snapshot.finished)
    failed.didFinish(); precondition(!failed.snapshot.finished && failed.snapshot.failure == "test failure")
    pending.didFail("late failure"); precondition(!pending.snapshot.finished)
    print("PASS recording state: pending and failed delegates cannot report finalized success")
  }
}

final class Capture:NSObject,SCStreamOutput,SCRecordingOutputDelegate,SCStreamDelegate {
  let directory:URL;let file:FileHandle;let context=CIContext();let logLock=NSLock()
  var count=0,complete=0,failures=0,inconclusive=0,correct=0,gaps=0
  var lastTime:Double?;let recordingState=RecordingState()
  var statuses:[String:Int]=[:]
  init(_ directory:URL) throws {
    self.directory=directory
    FileManager.default.createFile(atPath:directory.appendingPathComponent("frames.jsonl").path,contents:nil)
    file=try FileHandle(forWritingTo:directory.appendingPathComponent("frames.jsonl"))
  }
  func log(_ original:[String:Any]) {
    var row=original
    if row["host_time"] == nil {row["host_time"]=ProcessInfo.processInfo.systemUptime}
    guard var data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else {return}
    data.append(10)
    logLock.lock();defer {logLock.unlock()}
    try? file.write(contentsOf:data)
  }
  func recordingOutputDidFinishRecording(_ output:SCRecordingOutput) {
    recordingState.didFinish();log(["recording_finished":true,"classification":"recording_event"])
  }
  func recordingOutput(_ output:SCRecordingOutput,didFailWithError error:Error) {
    recordingState.didFail(error.localizedDescription);log(["recording_error":error.localizedDescription])
  }
  func stream(_ stream:SCStream,didStopWithError error:Error) { log(["stream_error":error.localizedDescription]) }
  func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
    guard type == .screen else { return }
    defer { count += 1 }
    let info=(CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first ?? [:]
    let status=(info[.status] as? Int) ?? -1
    statuses[String(status),default:0]+=1
    let time=buffer.presentationTimeStamp.seconds
    var row:[String:Any]=["sample":count,"pts":time,"host_time":ProcessInfo.processInfo.systemUptime,"status":status]
    for (key,value) in info { row[key.rawValue]=String(describing:value) }
    if let lastTime,time-lastTime>0.025 { row["coverage_gap_seconds"]=time-lastTime;gaps+=1 }
    lastTime=time
    guard status==SCFrameStatus.complete.rawValue,let image=buffer.imageBuffer else { row["classification"]="inconclusive_noncomplete_status";log(row);return }
    complete+=1
    CVPixelBufferLockBaseAddress(image,.readOnly)
    let width=CVPixelBufferGetWidth(image),height=CVPixelBufferGetHeight(image),stride=CVPixelBufferGetBytesPerRow(image)
    row["pixel_width"]=width;row["pixel_height"]=height
    let pixels=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt8.self)
    var boxes:[Component]=[]
    for y in 0..<height {
      var x=0
      while x<width {
        let q=pixels+y*stride+x*4
        guard let color=MarkerOracle.color(q[0],q[1],q[2]) else { x+=1;continue }
        let start=x
        while x<width { let p=pixels+y*stride+x*4; if MarkerOracle.color(p[0],p[1],p[2]) != color { break };x+=1 }
        if x-start>=2 {
          if let i=boxes.lastIndex(where:{$0.color==color && $0.bottom==y-1 && $0.x<x && $0.right>start}) { boxes[i].x=min(boxes[i].x,start);boxes[i].right=max(boxes[i].right,x);boxes[i].bottom=y }
          else { boxes.append(Component(color:color,x:start,y:y,right:x,bottom:y)) }
        }
      }
    }
    let components=boxes.filter{$0.height>=2}
    let scale=(info[.contentScale] as? NSNumber)?.doubleValue ?? -1
    var panes=MarkerOracle.evaluate(components,contentScale:scale,width:width,height:height)
    for i in panes.indices where panes[i]["result"] as? String == "correct" {
      guard let markers=panes[i]["metal"] as? [[Int]],markers.count==1 else {continue}
      let m=markers[0],cw=MarkerOracle.cellWidth,ch=MarkerOracle.cellHeight
      let x=m[0],y=m[1]+3*ch // rectangle starts row 4; barcode starts row 7.
      guard x+8*cw<=width && y+4*ch<=height else {panes[i]["barcode_status"]="capture_clipped";continue}
      var code:UInt32=0
      for bit in 0..<32 {
        let p=pixels+(y+(bit/8)*ch+ch/2)*stride+(x+(bit%8)*cw+cw/2)*4
        if p[0]>180 && p[1]>180 && p[2]>180 {code |= 1<<bit}
      }
      let generation=(code>>4)&0xffff,checksum=(code>>20)&0xff
      if code&0xf==0xa && code>>28==0x5 && checksum==((generation^(generation>>8)^UInt32(i)^0xa5)&0xff) {
        panes[i]["validated_visible_generation"]=generation
        panes[i]["visible_final_flag"]=(generation & 0x8000) != 0
        panes[i]["visible_rows"]=(generation >> 8) & 0x7f
        panes[i]["visible_columns"]=generation & 0xff
      } else {panes[i]["barcode_status"]="invalid_sentinel_or_checksum"}
    }
    CVPixelBufferUnlockBaseAddress(image,.readOnly)
    let bad=panes.contains{$0["result"] as? String == "failure"}
    let uncertain=panes.contains{$0["result"] as? String == "inconclusive"}
    if bad { failures+=1 } else if uncertain { inconclusive+=1 } else { correct+=1 }
    row["panes"]=panes;row["classification"]=bad ? "failure" : (uncertain ? "inconclusive" : "correct")
    row["components"]=components.map{["color":$0.color,"rect":$0.json] as [String:Any]}
    if bad || uncertain || complete%30==0 || complete<=3 {
      let name=String(format:"sample-%04d.png",count);row["image"]=name
      let ci=CIImage(cvPixelBuffer:image)
      if let cg=context.createCGImage(ci,from:ci.extent),let dest=CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil) { CGImageDestinationAddImage(dest,cg,nil);CGImageDestinationFinalize(dest) }
    }
    log(row)
  }
}

@main struct Main {
  @MainActor static func main() async throws {
    if CommandLine.arguments.contains("--self-test") { MarkerOracle.selfTest();RecordingState.selfTest();return }
    guard CommandLine.arguments.count==5,let id=UInt32(CommandLine.arguments[1]),
      let pid=Int32(CommandLine.arguments[3]),let duration=Double(CommandLine.arguments[4]),duration>0,duration<=60 else {fatalError("Usage: Capture windowID output ownedPID seconds")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let directory=URL(fileURLWithPath:CommandLine.arguments[2])
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let identity=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("identity.json"))) as! [String:Any]
    MarkerOracle.cellWidth=identity["cell_width_pixels"] as! Int
    MarkerOracle.cellHeight=identity["cell_height_pixels"] as! Int
    guard CGPreflightScreenCaptureAccess() else {fatalError("Screen recording permission unavailable; no prompt requested")}
    let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
    guard let window=content.windows.first(where:{$0.windowID==id && $0.owningApplication?.processID==pid}) else { fatalError("Owned window unavailable") }
    let filter=SCContentFilter(desktopIndependentWindow:window)
    let config=SCStreamConfiguration();config.width=2600;config.height=1800
    config.minimumFrameInterval=CMTime(value:1,timescale:60);config.pixelFormat=kCVPixelFormatType_32BGRA
    config.showsCursor=false;config.capturesAudio=false;config.captureMicrophone=false
    config.scalesToFit=false;config.preservesAspectRatio=true;config.ignoreShadowsSingleWindow=true
    config.includeChildWindows=false;config.queueDepth=8;config.colorSpaceName=CGColorSpace.sRGB
    let capture=try Capture(directory),stream=SCStream(filter:filter,configuration:config,delegate:capture)
    try stream.addStreamOutput(capture,type:.screen,sampleHandlerQueue:DispatchQueue(label:"capture"))
    let recConfig=SCRecordingOutputConfiguration();recConfig.outputURL=directory.appendingPathComponent("capture.mp4")
    let recording=SCRecordingOutput(configuration:recConfig,delegate:capture);try stream.addRecordingOutput(recording)
    try await stream.startCapture();try Data("ready".utf8).write(to:directory.appendingPathComponent("ready"))
    try await Task.sleep(for:.seconds(duration))
    do { try await stream.stopCapture() } catch { capture.log(["stop_error":error.localizedDescription]) }
    for _ in 0..<100 {
      let state=capture.recordingState.snapshot
      if state.finished || state.failure != nil { break }
      try await Task.sleep(for:.milliseconds(20))
    }
    let state=capture.recordingState.snapshot
    let videoAttributes=try? FileManager.default.attributesOfItem(atPath:recConfig.outputURL.path)
    let videoBytes=(videoAttributes?[.size] as? NSNumber)?.int64Value ?? 0
    let videoRegular=videoAttributes?[.type] as? FileAttributeType == .typeRegular
    let recordingValid=state.finished && videoRegular && videoBytes>0
    var result:[String:Any]=["oracle_scope":"absolute marker dimensions and visible PTY generation only; no native pane-local reference or drawable presented-handler proof","samples":capture.count,"complete_frames":capture.complete,"correct_frames":capture.correct,"failure_frames":capture.failures,"inconclusive_complete_frames":capture.inconclusive,"timestamp_gaps":capture.gaps,"statuses":capture.statuses,"recording_finished":state.finished,"recording_valid":recordingValid,"video_bytes":videoBytes,"scope":"Pane-specific absolute dimensions and checksum-visible PTY generations only; offsets, gaps, incomplete and inconclusive samples are not verified."]
    if let failure=state.failure { result["recording_error"]=failure }
    if !recordingValid { result["recording_validation_error"]="Recording did not finalize successfully with a nonempty regular MP4 file" }
    try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("summary.json"))
    print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    guard recordingValid else { throw NSError(domain:"RenderingProof",code:1,userInfo:[NSLocalizedDescriptionKey:result["recording_validation_error"]!]) }
  }
}
