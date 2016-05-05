package htmlelements
{
  import flash.display.Sprite;
  import flash.events.*;
  import flash.net.NetConnection;
  import flash.net.NetStream;
  import flash.net.NetStreamPlayOptions;
  import flash.net.NetStreamPlayTransitions;
  import flash.media.Video;
  import flash.media.SoundTransform;
  import flash.utils.*;

  import org.osflash.thunderbolt.Logger;

  import FlashMediaElement;
  import HtmlMediaEvent;

  public class VideoElement extends Sprite implements IMediaElement
  {
    private var _currentUrl:String = "";
    private var _autoplay:Boolean = true;
    private var _preload:String = "";

    private var _connection:NetConnection;
    private var _stream:NetStream;
    private var _video:Video;
    private var _element:FlashMediaElement;
    private var _soundTransform:SoundTransform;
    private var _oldVolume:Number = 1;

    // event values
    private var _duration:Number = 0;
    private var _framerate:Number;
    private var _isPaused:Boolean = true;
    private var _isEnded:Boolean = false;
    private var _volume:Number = 1;
    private var _isMuted:Boolean = false;
    private var _isPreloading:Boolean = false;
    private var _isSeeking:Boolean = false;

    private var _bytesLoaded:Number = 0;
    private var _bytesTotal:Number = 0;
    private var _bufferedTime:Number = 0;
    private var _bufferEmpty:Boolean = false;
    private var _bufferingChanged:Boolean = false;
    private var _seekOffset:Number = 0;

    private var _pendingSeek:Number = -1;
    private var _playerSticks:Boolean = false;

    private var _videoWidth:Number = -1;
    private var _videoHeight:Number = -1;

    private var _timer:Timer;

    private var _isRTMP:Boolean = false;
    private var _streamer:String = "";
    private var _isConnected:Boolean = false;
    private var _playWhenConnected:Boolean = false;
    private var _hasStartedPlaying:Boolean = false;

    private var _parentReference:Object;
    private var _pseudoStreamingEnabled:Boolean = false;
    private var _pseudoStreamingStartQueryParam:String = "start";

    // clip support
    private var _clip_begin:Number = -1;
    private var _clip_end:Number = -1;

    public function setReference(arg:Object):void {
      _parentReference = arg;
    }

    public function setSize(width:Number, height:Number):void {
      _video.width = width;
      _video.height = height;
    }

    public function setPseudoStreaming(enablePseudoStreaming:Boolean):void {
      _pseudoStreamingEnabled = enablePseudoStreaming;
    }

    public function setPseudoStreamingStartParam(pseudoStreamingStartQueryParam:String):void {
      _pseudoStreamingStartQueryParam = pseudoStreamingStartQueryParam;
    }

    public function get video():Video {
      return _video;
    }

    public function get videoHeight():Number {
      return _videoHeight;
    }

    public function get videoWidth():Number {
      return _videoWidth;
    }


    public function duration():Number {
      if (_clip_begin != -1 && _clip_end != -1) {
        return _clip_end - _clip_begin;
      } else if (_clip_begin != -1) {
        return _duration - _clip_begin;
      } else {
        return _duration;
      }
    }

    public function currentProgress():Number {
      if(_stream != null) {
        return Math.round(_stream.bytesLoaded/_stream.bytesTotal*100);
      } else {
        return 0;
      }
    }

    public function currentTime():Number {
      var currentTime:Number = 0;
      if (_playerSticks && _pendingSeek > -1) {
        currentTime = _pendingSeek;
      } else if (_stream != null) {
        currentTime = _stream.time;
        if (_pseudoStreamingEnabled) {
          currentTime += _seekOffset;
        }
      }

      //clip support
      if (_clip_begin != -1) {
        return currentTime - _clip_begin;
      }
      return currentTime;
    }


    // (1) load()
    // calls _connection.connect();
    // waits for NetConnection.Connect.Success
    // _stream gets created


    public function VideoElement(element:FlashMediaElement, autoplay:Boolean, preload:String, timerRate:Number, startVolume:Number, streamer:String)
    {
      _element = element;
      _autoplay = autoplay;
      _volume = startVolume;
      _preload = preload;
      _streamer = streamer;

      _video = new Video();
      addChild(_video);

      _connection = new NetConnection();
      _connection.client = { onBWDone: function():void{} };
      _connection.addEventListener(NetStatusEvent.NET_STATUS, netStatusHandler);
      _connection.addEventListener(SecurityErrorEvent.SECURITY_ERROR, securityErrorHandler);
      //_connection.connect(null);

      _timer = new Timer(timerRate);
      _timer.addEventListener("timer", timerHandler);

      Logger.includeTime = false;
      Logger.showCaller = false;
    }

    private function timerHandler(e:TimerEvent):void {

      _bytesLoaded = _stream.bytesLoaded;
      _bytesTotal = _stream.bytesTotal;

      //clip support
      if ((_clip_end != -1) && (currentTime > duration)) {
        stop();
        return;       
      }

      if (!_isPaused) {
        sendEvent(HtmlMediaEvent.TIMEUPDATE);
      }

      //Logger.debug("bytes", _bytesLoaded, _bytesTotal);

      if (_bytesLoaded < _bytesTotal)
        sendEvent(HtmlMediaEvent.PROGRESS);

    }

    // internal events
    private function netStatusHandler(event:NetStatusEvent):void {
      Logger.debug("netStatus " + event.info.code + " isPreloading: " + _isPreloading);

      switch (event.info.code) {

        case "NetStream.Buffer.Empty":
          _bufferEmpty = true;
          if (_isEnded) { 
            sendEvent(HtmlMediaEvent.ENDED);
            _timer.stop();
          }
          break;

        case "NetStream.Buffer.Full":
          _bytesLoaded = _stream.bytesLoaded;
          _bytesTotal = _stream.bytesTotal;
          _bufferEmpty = false;

          sendEvent(HtmlMediaEvent.PROGRESS);
          break;

        case "NetConnection.Connect.Success":
          connectStream();
          break;
        case "NetStream.Play.StreamNotFound":
          Logger.debug("Unable to locate video");
          break;

        // STREAM
        case "NetStream.Play.Start":
          _pendingSeek = -1;
          if (!_isPreloading && !_isPaused) {
            sendEvent(HtmlMediaEvent.CANPLAY);
            sendEvent(HtmlMediaEvent.PLAY);
            sendEvent(HtmlMediaEvent.PLAYING);
            _timer.start();
          }
          break;

        case "NetStream.SeekStart.Notify":
          _isSeeking = true;
          setTimeout(playIfStuck, 300);
          break;

        case "NetStream.Seek.Complete":
        case "NetStream.Seek.Notify":
          _isSeeking = false;
          sendEvent(HtmlMediaEvent.PROGRESS);
          sendEvent(HtmlMediaEvent.TIMEUPDATE);
          sendEvent(HtmlMediaEvent.SEEKED);
          break;
          
        case "NetStream.Pause.Notify":
          _isPaused = true;
          sendEvent(HtmlMediaEvent.PAUSE);
          break;

        case "NetStream.Play.Stop":
          _isEnded = true;
          _isPaused = false;
          // The video often continues to play until the buffer is empty
          //_timer.stop(); 
          //_bufferEmpty ? sendEvent(HtmlMediaEvent.ENDED) : null;
          break;

      }
    }

    // Workaround for Red5 bug, which doesn't send NetStream.Seek.Complete
    // This event only comes after we click play again
    private function playIfStuck():void {
      if (_isSeeking && _isPaused) {
        _playerSticks = true;
        Logger.info("Stream time: " + _stream.time + " Player time: " + currentTime());
        sendEvent(HtmlMediaEvent.PROGRESS);
        sendEvent(HtmlMediaEvent.TIMEUPDATE);
        sendEvent(HtmlMediaEvent.SEEKED);
        Logger.warn("Play/Pausing because I haven't received NetStream.Seek.Complete");
      }
    }

    private function securityErrorHandler(event:SecurityErrorEvent):void {
      Logger.error("securityErrorHandler: " + event);
    }

    private function asyncErrorHandler(event:AsyncErrorEvent):void {
      // ignore AsyncErrorEvent events.
    }


    private function onMetaDataHandler(info:Object):void {
      // Sets the duration everytime so it gets updated when switching video source
      _duration = info.duration;
      _framerate = info.framerate;
      _videoWidth = info.width;
      _videoHeight = info.height;


      // set size?
      Logger.debug("received metadata");
      sendEvent(HtmlMediaEvent.LOADEDMETADATA);



      if (_isPreloading) {
        _stream.pause();
        _video.attachNetStream(_stream);
        _soundTransform = new SoundTransform(_volume);
        _stream.soundTransform = _soundTransform;
        _hasStartedPlaying = true;

        _isPaused = true;
        _isPreloading = false;
        Logger.debug("done preloading");

        sendEvent(HtmlMediaEvent.PROGRESS);
        sendEvent(HtmlMediaEvent.TIMEUPDATE);

      }
    }




    // interface members
    public function setSrc(url:String):void {
      if (_isConnected && _stream) {
        // stop and restart
        _stream.pause();
        _video.clear();
        _video.attachNetStream(null);
      }

      _currentUrl = url;
      _isRTMP = !!_currentUrl.match(/^rtmp(s|t|e|te)?\:\/\//) || _streamer != "";
      _isConnected = false;
      _hasStartedPlaying = false;
    }

    public function load():void {
      // disconnect existing stream and connection
      if (_isConnected && _stream) {
        _stream.pause();
        _stream.close();
        _connection.close();
      }
      _isConnected = false;
      _isPreloading = false;


      _isEnded = false;
      _bufferEmpty = false;

      // start new connection
      if (_isRTMP) {
        var rtmpInfo:Object = parseRTMP(_currentUrl);
        if (_streamer != "") {
          rtmpInfo.server = _streamer;
          rtmpInfo.stream = _currentUrl;
          _clip_start = rtmpInfo.clip_start;
          _clip_end = rtmpInfo.clip_end;
        }
        _connection.connect(rtmpInfo.server);
      } else {
        _connection.connect(null);
      }

      // in a few moments the "NetConnection.Connect.Success" event will fire
      // and call createConnection which finishes the "load" sequence
      sendEvent(HtmlMediaEvent.LOADSTART);
    }


    private function connectStream():void {
      Logger.debug("connectStream");
      _stream = new NetStream(_connection);

      // set the buffer to ensure nice playback
      _stream.bufferTime = 1;
      _stream.bufferTimeMax = 3;

      _stream.addEventListener(NetStatusEvent.NET_STATUS, netStatusHandler); // same event as connection
      _stream.addEventListener(AsyncErrorEvent.ASYNC_ERROR, asyncErrorHandler);

      var customClient:Object = new Object();
      customClient.onMetaData = onMetaDataHandler;
      _stream.client = customClient;


      // start downloading without playing )based on preload and play() hasn't been called)
      // I wish flash had a load() command to make this less awkward
      if (_preload != "none" && !_playWhenConnected) {
        // explicitly set the sound since it could have come before the connection was made
        _soundTransform = new SoundTransform(0);
        _stream.soundTransform = _soundTransform;

        _isPaused = true;
        _isPreloading = true;
        //stream.bufferTime = 20;
        if (_isRTMP){
          var rtmpInfo:Object = parseRTMP(_currentUrl);
          _clip_start = rtmpInfo.clip_start;
          _clip_end = rtmpInfo.clip_end;
          _stream.play(rtmpInfo.stream, 0);
	      } else {
          _stream.play(getCurrentUrl(0), 0);
       	}

        //_stream.pause();
        //
        //sendEvent(HtmlMediaEvent.PAUSE); // have to send this because the "playing" event gets sent via event handlers
      } else {
        // explicitly set the sound since it could have come before the connection was made
        _soundTransform = new SoundTransform(_volume);
        _stream.soundTransform = _soundTransform;

        _video.attachNetStream(_stream);
      }

      _isConnected = true;

      if (_playWhenConnected && !_hasStartedPlaying) {
        play();
        _playWhenConnected = false;
      }

    }

    // Seamlessly switches to a different derivative of the same stream
    public function switchStream(url:String):void {
      if (_isRTMP) {
        var opts:NetStreamPlayOptions = new NetStreamPlayOptions();
        opts.oldStreamName = parseRTMP(_currentUrl).stream;
        rtmpInfo = parseRTMP(url);
        opts.streamName = rtmpInfo.stream;
        opts.transition = NetStreamPlayTransitions.SWITCH;
        _stream.play2(opts);
        _currentUrl = url;
        _clip_start = rtmpInfo.clip_start;
        _clip_end = rtmpInfo.clip_end;
      } else {
        _stream.play(getCurrentUrl(0), 0);
      }
    }

    public function play():void {

      if (!_hasStartedPlaying && !_isConnected) {
        _playWhenConnected = true;
        load();
        return;
      }

      if (_hasStartedPlaying) {
          _stream.resume();
          _isPaused = false;
      } else {

        if (_isRTMP) {
          var rtmpInfo:Object = parseRTMP(_currentUrl);
          _stream.play(rtmpInfo.stream);
        } else {
          _stream.play(getCurrentUrl(0));
        }
        _timer.start();
        _isPaused = false;
        _hasStartedPlaying = true;

        // don't toss play/playing events here, because we haven't sent a
        // canplay / loadeddata event yet. that'll be handled in the net
        // event listener
      }

    }

    public function pause():void {
      if (_stream == null)
        return;

      _stream.pause();
      _isPaused = true;

      if (_bytesLoaded == _bytesTotal) {
        _timer.stop();
      }

      _isPaused = true;
      sendEvent(HtmlMediaEvent.PAUSE);
    }

    public function stop():void {
      if (_stream == null)
        return;

      _stream.close();
      _isPaused = false;
      _timer.stop();
      sendEvent(HtmlMediaEvent.STOP);
    }


    public function setCurrentTime(pos:Number):void {
      if (_stream == null) {
        return;
      }

      // pos is relative to click start
      if (_clip_start != -1) {
        pos = pos + _clip_start;
      }
      // don't allow seeking past clip end
      if ((_clip_end != _duration) && (pos > _clip_end)) {
        pos = _clip_end;
      }

      // Calculate the position of the buffered video
      var bufferPosition:Number = _bytesLoaded / _bytesTotal * _duration;

      if (_pseudoStreamingEnabled) {
        sendEvent(HtmlMediaEvent.SEEKING);
        // Normal seek if it is in buffer and this is the first seek
        if (pos < bufferPosition && _seekOffset == 0) {
          _stream.seek(pos);
        }
        else {
          // Uses server-side pseudo-streaming to seek
          _stream.play(getCurrentUrl(pos));
          _seekOffset = pos;
        }
      }
      else {
        _pendingSeek = pos;
        sendEvent(HtmlMediaEvent.SEEKING);
        _stream.seek(pos);
      }

      if (!_isEnded) {
        sendEvent(HtmlMediaEvent.TIMEUPDATE);
      }
    }

    public function setVolume(volume:Number):void {
      if (_stream != null) {
        _soundTransform = new SoundTransform(volume);
        _stream.soundTransform = _soundTransform;
      }

      _volume = volume;

      _isMuted = (_volume == 0);

      sendEvent(HtmlMediaEvent.VOLUMECHANGE);
    }

    public function getVolume():Number {
      if(_isMuted) {
        return 0;
      } else {
        return _volume;
      }
    }

    public function setMuted(muted:Boolean):void {

      if (_isMuted == muted)
        return;

      if (muted) {
        _oldVolume = (_stream == null) ? _oldVolume : _stream.soundTransform.volume;
        setVolume(0);
      } else {
        setVolume(_oldVolume);
      }

      _isMuted = muted;
    }


    private function sendEvent(eventName:String):void {

      // calculate this to mimic HTML5
      _bufferedTime = _bytesLoaded / _bytesTotal * _duration;

      // build JSON
      var values:String =
        "duration:" + _duration +
          ",framerate:" + _framerate +
          ",currentTime:" + currentTime() +
          ",muted:" + _isMuted +
          ",paused:" + _isPaused +
          ",ended:" + _isEnded +
          ",volume:" + _volume +
          ",src:\"" + _currentUrl + "\"" +
          ",bytesTotal:" + _bytesTotal +
          ",bufferedBytes:" + _bytesLoaded +
          ",bufferedTime:" + _bufferedTime +
          ",videoWidth:" + _videoWidth +
          ",videoHeight:" + _videoHeight +
          "";

      _element.sendEvent(eventName, values);
    }

    private function parseRTMP(url:String):Object {
      var match:Array = url.match(/(.*)\/((flv|mp4|mp3):.*)/);
      var queryString:Array = url.match(/\?(.*)/);
      var rtmpInfo:Object = {
        server: null,
        stream: null,
        clip_start: null,
        clip_end: null
      };

      if (match) {
        //TODO set clip_start and clip_end from mediafragment in url 
        rtmpInfo.server = match[1];
        if (queryString) {
          var mediafragment:Array = queryString.match(/t=(.*)&?/)
          if (mediafragment) {
            var timepoints:Array = mediafragment.match(/(\d*),(\d*)/)
            rtmpInfo.start_time = timepoints[1];
            if (timepoints[2]) {
              rtmpInfo.end_time = timepoints[2];
            }
          }
          var token:Array = queryString.match(/token=(.*)&?/)
          rtmpInfo.server += "?token=" + token[1];
        }
        rtmpInfo.stream = match[2];
      }
      else {
        rtmpInfo.server = url.replace(/\/[^\/]+$/,"/");
        rtmpInfo.stream = url.split("/").pop();
      }

      Logger.debug("parseRTMP - server: " + rtmpInfo.server + " stream: " + rtmpInfo.stream + " clip_start: " + rtmpInfo.clip_start + " clip_end: " + rtmpInfo.clip_end);

      return rtmpInfo;
    }

    private function getCurrentUrl(pos:Number):String {
      var url:String = _currentUrl;
      if (_pseudoStreamingEnabled) {
        if (url.indexOf('?') > -1) {
          url = url + '&' + _pseudoStreamingStartQueryParam + '=' + pos;
        }
        else {
          url = url + '?' + _pseudoStreamingStartQueryParam + '=' + pos;
        }
      }
      return url;
    }
  }
}
