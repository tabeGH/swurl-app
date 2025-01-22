import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';

void main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize cameras before running app
  final cameras = await availableCameras();
  if (cameras.isEmpty) {
    print('No cameras found');
    return;
  }

  runApp(CameraApp());
}

class CameraApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Continuous Camera Recording',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
      ),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatelessWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Recording'),
      ),
      body: const SafeArea(
        child: ContinuousRecording(
          bufferDurationSeconds: 30, // Customize buffer duration here
        ),
      ),
    );
  }
}

// Rest of the ContinuousRecording class implementation remains the same
class ContinuousRecording extends StatefulWidget {
  final int bufferDurationSeconds;

  const ContinuousRecording({
    Key? key,
    this.bufferDurationSeconds = 30,
  }) : super(key: key);

  @override
  State<ContinuousRecording> createState() => _ContinuousRecordingState();
}

class _ContinuousRecordingState extends State<ContinuousRecording> {
  CameraController? _controller;
  Queue<File> _videoSegments = Queue();
  Timer? _recordingTimer;
  bool _isRecording = false;
  bool _isSaving = false;
  int _currentSegmentDuration = 5;
  VideoPlayerController? _previewController;
  String? _lastSavedVideoPath;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final firstCamera = cameras.first;

    _controller = CameraController(
      firstCamera,
      ResolutionPreset.medium,
      enableAudio: true,
    );

    await _controller!.initialize();
    if (mounted) {
      setState(() {});
      _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (!_controller!.value.isInitialized) return;

    _isRecording = true;
    await _recordSegment();

    _recordingTimer = Timer.periodic(
      Duration(seconds: _currentSegmentDuration),
          (_) => _recordSegment(),
    );
  }

  Future<void> _recordSegment() async {
    if (!_isRecording) return;

    final Directory tempDir = await getTemporaryDirectory();
    final String filePath = '${tempDir.path}/segment_${DateTime.now().millisecondsSinceEpoch}.mp4';

    try {
      await _controller!.startVideoRecording();
      await Future.delayed(Duration(seconds: _currentSegmentDuration));
      final XFile videoFile = await _controller!.stopVideoRecording();

      _videoSegments.add(File(videoFile.path));

      while (_videoSegments.length * _currentSegmentDuration > widget.bufferDurationSeconds) {
        final File oldFile = _videoSegments.removeFirst();
        await oldFile.delete();
      }
    } catch (e) {
      print('Error recording segment: $e');
    }
  }

  Future<String?> saveLastSeconds() async {
    if (_videoSegments.isEmpty) return null;

    setState(() {
      _isRecording = false;
      _isSaving = true;
    });

    _recordingTimer?.cancel();

    try {
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String outputPath = '${appDir.path}/saved_recording_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final String concatFilePath = '${appDir.path}/concat_list.txt';

      // Create a concat demuxer file for FFmpeg
      final StringBuffer concatBuffer = StringBuffer();
      for (final File segment in _videoSegments) {
        concatBuffer.writeln("file '${segment.path}'");
      }
      await File(concatFilePath).writeAsString(concatBuffer.toString());

      // Use FFmpeg to concatenate videos
      final session = await FFmpegKit.execute(
          '-f concat -safe 0 -i "$concatFilePath" -c copy "$outputPath"'
      );

      final ReturnCode? returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        _lastSavedVideoPath = outputPath;
        await _initializePreviewPlayer(outputPath);
        return outputPath;
      } else {
        print('FFmpeg process exited with error');
        return null;
      }
    } catch (e) {
      print('Error saving video: $e');
      return null;
    } finally {
      setState(() {
        _isSaving = false;
      });
      _startRecording();
    }
  }

  Future<void> _initializePreviewPlayer(String videoPath) async {
    _previewController?.dispose();
    _previewController = VideoPlayerController.file(File(videoPath));

    await _previewController!.initialize();
    setState(() {});
  }

  Widget _buildPreviewSection() {
    if (_previewController == null || !_previewController!.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 200,
      child: Column(
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: _previewController!.value.aspectRatio,
              child: VideoPlayer(_previewController!),
            ),
          ),
          VideoProgressIndicator(_previewController!, allowScrubbing: true),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(
                  _previewController!.value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                onPressed: () {
                  setState(() {
                    _previewController!.value.isPlaying
                        ? _previewController!.pause()
                        : _previewController!.play();
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.replay),
                onPressed: () {
                  _previewController!.seekTo(Duration.zero);
                  _previewController!.play();
                },
              ),
              if (_lastSavedVideoPath != null)
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: () {
                    // Implement sharing functionality here
                    // You could use share_plus package
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: CameraPreview(_controller!),
        ),
        _buildPreviewSection(),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ElevatedButton(
            onPressed: _isSaving
                ? null
                : () async {
              final String? savedPath = await saveLastSeconds();
              if (savedPath != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Video saved to: $savedPath')),
                );
              }
            },
            child: _isSaving
                ? const CircularProgressIndicator()
                : Text('Save Last ${widget.bufferDurationSeconds} Seconds'),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _controller?.dispose();
    _previewController?.dispose();
    super.dispose();
  }
}