import UIKit
import WebRTC
import Starscream
import SwiftyJSON

class UVCViewController: UIViewController, WebSocketDelegate,
RTCPeerConnectionDelegate, RTCEAGLVideoViewDelegate {
    func websocketDidConnect(socket: WebSocketClient) {
        LOG()
    }
    
    func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        LOG("error: \(String(describing: error?.localizedDescription))")
    }
    
    func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        //LOG("message: \(text)")
        // 受け取ったメッセージをJSONとしてパース
        //let jsonMessage = JSON.init(parseJSON: text);
        let jsonMessage = JSON.init(parseJSON: text);
        let type = jsonMessage["what"].stringValue
        
        LOG("msg.what:  \(jsonMessage["what"].stringValue)" );
        LOG("msg.type:  \(jsonMessage["type"].stringValue)" );
        
        switch (type) {
        case "offer":
            // offerを受け取った時の処理
            LOG("Received offer ...")
            let dataStr = jsonMessage["data"].stringValue;
            let dataMessage = JSON.init(parseJSON: dataStr);
            let offer = RTCSessionDescription(
                type: RTCSessionDescription.type(for: type),
                sdp: dataMessage["sdp"].stringValue)
            self.setOffer(offer);
            break;
        case "answer":
            // answerを受け取った時の処理
            LOG("Received answer ...")
            break;
        case "candidate":
            LOG("Received candidate ...")
            break;
        case "geticecandidate":
            LOG("Received geticecandidate ...")
            break;
        case "iceCandidates":
            LOG("Received iceCandidates ...")
            jsonMessage["data"].forEach{(_, data) in
                addIceCandidate(RTCIceCandidate(
                    sdp:data["candidate"].stringValue,
                    sdpMLineIndex:data["sdpMLineIndex"].int32Value,
                    sdpMid:data["sdpMid"].stringValue
                ));
            }
            break;
        case "close":
            LOG("peer is closed ...")
            hangUp()
            break;
        case "message":
            LOG(text);
            break;
        default:
            return
        }
    }
    
    func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        LOG("data.count: \(data.count)");
    }
    
    
    let WS_SERVER_URL:String = "wss://raspberrypi2.local:8090/stream/webrtc";
    let STUN_URL:String = "stun:raspberrypi2.local:3478";
    
    var websocket: WebSocket! = nil
    
    var peerConnectionFactory: RTCPeerConnectionFactory! = nil
    var peerConnection: RTCPeerConnection! = nil
    
    var remoteVideoTrack: RTCVideoTrack?
    var remoteAudioTrack: RTCAudioTrack?
    
    //var localAudioTrack: RTCAudioTrack?
    
    var audioSource: RTCAudioSource?
    var videoSource: RTCAVFoundationVideoSource?
    var recorder:AVAudioRecorder!

    @IBOutlet weak var remoteVideoView: RTCEAGLVideoView!
    
    @IBOutlet weak var waveformView: WaveformView!
    
    func configureAudioSession(block: () -> Void) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        block()
        session.unlockForConfiguration()
    }
    
    func startRecording() {
        LOG("startRec")
        /**
         M61 より RTCAudioSession という音声を扱うクラスが追加されました（プライベートな実装でしたがフレームワークで利用できるようになりました）。
         ほぼ AVAudioSession のプロパティの単純なラッパーです。このオブジェクトのプロパティを操作すると、
         WebRTC で使われるスレッドをロックしてから AVAudioSession のプロパティにアクセスしてくれます。
         プロパティやセッター以外は AVAudioSession を直接使っても問題ありません。
         音声に関しては iOS やハードウェアの制約があり、 WebRTC ライブラリの音声周りの実装もいろいろと制限されます。
         API の中でも特に情報がない分野なので、がんばって自力でどうにかしましょう。
         https://gist.github.com/szktty/999a34c64cc4ea60de43c4c1adc93203
        */
        let rtcSession = RTCAudioSession.sharedInstance();
        LOG(rtcSession.debugDescription);
        rtcSession.useManualAudio = true;
        let recorderSettings = [AVSampleRateKey: NSNumber(value:44100.0),
                                AVFormatIDKey: NSNumber(value:kAudioFormatAppleLossless),
                                AVNumberOfChannelsKey: NSNumber(value: 2),
                                AVEncoderAudioQualityKey: NSNumber(value: Int8(AVAudioQuality.min.rawValue))]
        
        let url:URL = URL(fileURLWithPath:"/dev/null");
        do {
            rtcSession.lockForConfiguration();
            try rtcSession.setCategory(AVAudioSessionCategoryPlayAndRecord,with:.duckOthers);            
            try rtcSession.setMode(AVAudioSessionModeVoiceChat);
            try rtcSession.overrideOutputAudioPort(AVAudioSessionPortOverride.speaker)
            try rtcSession.setActive(true)
            rtcSession.unlockForConfiguration();

            self.recorder = try AVAudioRecorder.init(url: url, settings: recorderSettings as [String : Any]);
            let displayLink: CADisplayLink = CADisplayLink(target: self, selector: #selector(UVCViewController.updateMeters));
            displayLink.add(to: RunLoop.current, forMode: RunLoopMode.commonModes);
            self.recorder.prepareToRecord();
            self.recorder.isMeteringEnabled = true;
            self.recorder.record();
        

            LOG("###recorder enabled");
        } catch let error as NSError {
            LOG("###########  recorder init failed!!!!!!");
            print("【エラーが発生しました : \(error)】")
        }
    }
//    func checkMicPermission() -> Bool {
//        var permissionCheck: Bool = false
//
//        switch RTCAudioSession.sharedInstance().recordPermission() {
//        case AVAudioSessionRecordPermission.granted:
//            permissionCheck = true
//        case AVAudioSessionRecordPermission.denied:
//            permissionCheck = false
//        case AVAudioSessionRecordPermission.undetermined:
//            AVAudioSession.sharedInstance().requestRecordPermission({ (granted) in
//                if granted {
//                    permissionCheck = true
//                } else {
//                    permissionCheck = false
//                }
//            })
//        }
//        return permissionCheck
//    }
    @objc func updateMeters() {
        var normalizedValue: Float
        recorder.updateMeters()
        normalizedValue = _normalizedPowerLevelFromDecibels(decibels: recorder.averagePower(forChannel: 0))
        self.waveformView.updateWithLevel(level: normalizedValue)
    }
    
    func _normalizedPowerLevelFromDecibels(decibels:Float) -> Float {
        if (decibels < -60.0 || decibels == 0.0) {
            return 0.0;
        }
        return pow((pow(10.0, 0.05 * decibels) - pow(10.0, 0.05 * -60.0)) * (1.0 / (1.0 - pow(10.0, 0.05 * -60.0))), 1.0 / 2.0);
    }
    
    // RTCVideoCapturer -> RTCVideoSource (RTCVideoCapturerDelegate) -> RTCVideoTrack -> RTCVideoRenderer (プロトコル)
    // RTCVideoCapturerDelegate を実装したクラスを用意
    // RTCVideoCapturer にセットし、 capturer(_:didCapture:) で受け取った映像フレームを加工してから
    // RTCVideoSource の　capturer(_:didCapture:) に加工後の映像フレームを渡します。
    // RTCVideoCapture と RTCVideoSource の間にフィルターを挟む

    override func viewDidLoad() {
        
        super.viewDidLoad();
        
//        if(checkMicPermission()) {
//        } else {
//            print("permission denied");
//            return;
//        }
        
        remoteVideoView.delegate = self;
        // RTCPeerConnectionFactoryの初期化
        peerConnectionFactory = RTCPeerConnectionFactory();
        
        // 音声と映像ソースの初期化
        startVideo();
        
        websocket = WebSocket(url: URL(string: WS_SERVER_URL)!);
        websocket.delegate = self;
        //自己証明を許可
        websocket.disableSSLCertValidation = true;
        websocket.connect();
        
        startRecording();
    }
    
    deinit {
        if peerConnection != nil {
            hangUp()
        }
        audioSource = nil
        videoSource = nil
        peerConnectionFactory = nil
    }
    
    func startVideo() {
        // 音声ソースの設定/生成
        let audioSourceConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        audioSource = peerConnectionFactory.audioSource(with: audioSourceConstraints)
        // 映像ソースの設定/生成
        let videoSourceConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil);
        videoSource = peerConnectionFactory.avFoundationVideoSource(with: videoSourceConstraints);

    }
    
    func prepareNewConnection() -> RTCPeerConnection {
        
        LOG("#prepareNewConnection")
        // STUN/TURNサーバーの指定
        let configuration = RTCConfiguration()
        configuration.iceServers = [RTCIceServer.init(urlStrings: [STUN_URL])]
        // PeerConecctionの設定(今回はなし)
        let peerConnectionConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil)
        // PeerConnectionの初期化
        let peerConnection = peerConnectionFactory.peerConnection(
            with: configuration, constraints: peerConnectionConstraints, delegate: self)
        
        return peerConnection
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
  
    @IBAction func connectButtonAction(_ sender: Any) {
        // Connectボタンを押した時
        // call リクエストを送る
        let jsonMsg: JSON = [
            "what":"call",
            "options":[
                "force_hw_vcodec": false,
                "vformat": "60"
            ]
        ];
        let message:String = jsonMsg.rawString(String.Encoding.utf8)!;
        LOG("#call");
        LOG(message);
        websocket.write(string:message);
        
    }
    
    
    func makeAnswer() {
        LOG("sending Answer. Creating remote session description...")
        if peerConnection == nil {
            LOG("peerConnection NOT exist!")
            return
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answerCompletion = { (answer: RTCSessionDescription?, error: Error?) in
            if error != nil { return }
            self.LOG("createAnswer() succsess")
            let setLocalDescCompletion = {(error: Error?) in
                if error != nil { return }
                self.LOG("setLocalDescription() succsess")
                // 相手に送る
                let jsonsdp: JSON = [
                    "type":"answer"
                    ,"sdp":answer!.sdp
                ]
                let jsonCandidate: JSON = [
                    "what": "answer" ,
                    "data": jsonsdp.rawString(String.Encoding.utf8) ?? ""
                ];
                let message = jsonCandidate.rawString(String.Encoding.utf8)!
                self.LOG("#answer");
                self.LOG(message);
                // 相手に送信
                self.websocket.write(string: message)
            }
            self.peerConnection.setLocalDescription(answer!, completionHandler: setLocalDescCompletion)
        }
        // Answerを生成
        self.peerConnection.answer(for: constraints, completionHandler: answerCompletion)
    }
    
    func setOffer(_ offer: RTCSessionDescription) {
        if peerConnection != nil {
            LOG("peerConnection alreay exist!")
        }
        // PeerConnectionを生成する
        self.peerConnection = prepareNewConnection()
        self.peerConnection.setRemoteDescription(offer, completionHandler: {(error: Error?) in
            if error == nil {
                self.LOG("setRemoteDescription(offer) succsess")
                // setRemoteDescriptionが成功したらAnswerを作る
                self.makeAnswer()
            } else {
                self.LOG("setRemoteDescription(offer) ERROR: " + error.debugDescription)
            }
        })
    }
    
    func setAnswer(_ answer: RTCSessionDescription) {
        if peerConnection == nil {
            LOG("peerConnection NOT exist!")
            return
        }
        // 受け取ったSDPを相手のSDPとして設定
        self.peerConnection.setRemoteDescription(answer, completionHandler: {
            (error: Error?) in
            if error == nil {
                self.LOG("setRemoteDescription(answer) succsess")
            } else {
                self.LOG("setRemoteDescription(answer) ERROR: " + error.debugDescription)
            }
        })
    }
    
    func addIceCandidate(_ candidate: RTCIceCandidate) {
        if peerConnection != nil {
            peerConnection.add(candidate)
        } else {
            LOG("PeerConnection not exist!")
        }
    }
    
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // 接続情報交換の状況が変化した際に呼ばれます
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        
        LOG("stream.audioTracks.count= " + stream.audioTracks.count.description);
        LOG("stream.videoTracks.count= " + stream.videoTracks.count.description);
        
        if (stream.audioTracks.count > 1 || stream.videoTracks.count > 1) {
            LOG("Weird-looking stream: " + stream.description)
            return
        }
        
        if (stream.audioTracks.count >= 1) {
            remoteAudioTrack = stream.audioTracks[0];
            //localAudioTrack = remoteAudioTrack;
        }
                
        // 映像/音声が追加された際に呼ばれます
        LOG("-- peer.onaddstream()")
        DispatchQueue.main.async(execute: { () -> Void in
            // mainスレッドで実行
            if (stream.videoTracks.count == 1) {
                // ビデオのトラックを取り出して
                self.remoteVideoTrack = stream.videoTracks[0];
                // remoteVideoViewに紐づける
                self.remoteVideoTrack?.add(self.remoteVideoView)
                //
                
                //self.startRecording();
            }
        })
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        // 映像/音声削除された際に呼ばれます
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // 接続情報の交換が必要になった際に呼ばれます
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // PeerConnectionの接続状況が変化した際に呼ばれます
        var state = ""
        switch (newState) {
        case RTCIceConnectionState.checking:
            state = "checking"
        case RTCIceConnectionState.completed:
            state = "completed"
        case RTCIceConnectionState.connected:
            state = "connected"
        case RTCIceConnectionState.closed:
            state = "closed"
            hangUp()
        case RTCIceConnectionState.failed:
            state = "failed"
            hangUp()
        case RTCIceConnectionState.disconnected:
            state = "disconnected"
        default:
            break
        }
        LOG("ICE connection Status has changed to \(state)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        // 接続先候補の探索状況が変化した際に呼ばれます
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Candidate(自分への接続先候補情報)が生成された際に呼ばれます
        if candidate.sdpMid != nil {
            //sendIceCandidate(candidate)
        } else {
            LOG("empty ice event")
        }
    }
    
    func sendIceCandidate(_ candidate: RTCIceCandidate) {
        LOG("---sending ICE candidate ---")
        let jsonCandidate: JSON = [
            "what": "addIceCandidate",
            "data": [
                "candidate": candidate.sdp,
                "sdpMLineIndex": candidate.sdpMLineIndex,
                "sdpMid": candidate.sdpMid!
            ]
        ]
        let message = jsonCandidate.rawString(String.Encoding.utf8)!
        LOG("#addIceCandidate");
        LOG(message);
        websocket.write(string: message)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // DataChannelが作られた際に呼ばれます
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        // Candidateが削除された際に呼ばれます
    }
    
    func videoView(_ videoView: RTCEAGLVideoView, didChangeVideoSize size: CGSize) {
        let width = self.view.frame.width
        let height = self.view.frame.width * size.height / size.width
        videoView.frame = CGRect(
            x: 0,
            y: (self.view.frame.height - height) / 2,
            width: width,
            height: height)
    }
    
    
    @IBAction func hangupButtonAction(_ sender: Any) {
        // HangUpボタンを押した時
        hangUp()
    }
    
    func hangUp() {
        if peerConnection != nil {
            if peerConnection.iceConnectionState != RTCIceConnectionState.closed {
                peerConnection.close()
                let jsonClose: JSON = [
                    "type": "close"
                ]
                LOG("sending close message")
                websocket.write(string: jsonClose.rawString()!)
            }
            if remoteVideoTrack != nil {
                remoteVideoTrack?.remove(remoteVideoView)
            }
            remoteVideoTrack = nil
            peerConnection = nil
            LOG("peerConnection is closed.")
        }
    }
    
    @IBAction func closeButtonAction(_ sender: Any) {
        // Closeボタンを押した時
        hangUp()
        websocket.disconnect()
        _ = self.navigationController?.popToRootViewController(animated: true)
    }
    
    func LOG(_ body: String = "",function: String = #function,line: Int = #line){
        print("[\(function) : \(line)] \(body)")
    }
}
