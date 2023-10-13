import 'dart:async';
import 'dart:convert' show base64, utf8;
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;
import 'package:flutter/foundation.dart';

import 'exceptions.dart';
import 'store.dart';
import 'dart:developer';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:http/http.dart' as http;
import "package:path/path.dart" as p;
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:uuid/uuid.dart';

/// This class is used for creating or resuming uploads.
class TusClient {
  /// Version of the tus protocol used by the client. The remote server needs to
  /// support this version, too.
  static final tusVersion = "1.0.0";

  //host to upoload to
  final host;

  /// The video folder in which create the video
  final String? folderId;

  /// Storage used to save and retrieve upload URLs by its fingerprint.
  // final TusStore? store;

  final File file;

  final Map<String, String>? metadata;

  /// Any additional headers
  final Map<String, String>? headers;

  /// Autentication token provided by Vimeo
  final String auth;

  /// The maximum payload size in bytes when uploading the file in chunks (512KB)
  final int maxChunkSize;

  late final Uuid _uuid;

  final Uri uploadUrl;

  int? _fileSize;

  String _fingerprint = "";

  String? _uploadMetadata;
  // Uri? get uploadUrl => _uploadUrl;

  int? _offset;

  bool _pauseUpload = false;

  Future? _chunkPatchFuture;

  TusClient(
    this.host,
    this.file,
    this.uploadUrl,
    this.auth, {
    this.headers,
    this.folderId,
    this.metadata = const {},
    this.maxChunkSize = 512 * 1024,
  }) {
    _fingerprint = generateFingerprint() ?? "";
    _uploadMetadata = generateMetadata();
  }

  /// Whether the client supports resuming
  // bool get resumingEnabled => store != null;

  /// The URI on the server for the file
  // Uri? get uploadUrl => _uploadUrl;

  /// The fingerprint of the file being uploaded
  String get fingerprint => _fingerprint;

  /// The 'Upload-Metadata' header sent to server
  String get uploadMetadata => _uploadMetadata ?? "";

  /// Override this method to use a custom Client
  http.Client getHttpClient() => http.Client();

  /// Create a new [upload] throwing [ProtocolException] on server error
  // create() async {
  //   _fileSize = await file.length();

  //   final client = getHttpClient();

  //   final videoCreationURL = host +
  //       '/users/$userId/videos?fields=upload.status,upload.upload_link,upload.approach';
  //   final createURL = _parseCreateUrl(videoCreationURL);

  //   final createHeaders = Map<String, String>.from(headers ?? {})
  //     ..addAll({
  //       HttpHeaders.authorizationHeader: auth,
  //       HttpHeaders.contentTypeHeader:
  //           ContentType('application', 'json').toString(),
  //       HttpHeaders.acceptHeader: 'application/vnd.vimeo.*+json;version=3.4',
  //     });
  //   final createBody = <String, dynamic>{
  //     "upload": {"approach": "tus", "size": "$_fileSize"},
  //     "folder_uri": "/users/$userId/projects/$folderId",
  //     "name": "${_uuid.v4()}",
  //     "hide_from_vimeo": true,
  //   };
  //   log("Info: ${jsonEncode(createBody)}");

  //   final response = await client.post(createURL,
  //       headers: createHeaders, body: jsonEncode(createBody));
  //   if (!(response.statusCode >= 200 && response.statusCode < 300) &&
  //       response.statusCode != 404) {
  //     throw ProtocolException(
  //         "Unexpected status code (${response.statusCode}) while creating upload");
  //   }

  //   dynamic resBody = jsonDecode(response.body);
  //   if (resBody['upload']['approach'] != 'tus') {
  //     throw ProtocolException("Upload not configured with tus protocol");
  //   }

  //   if (resBody['upload']['upload_link'] == "") {
  //     throw ProtocolException(
  //         "Missing upload url in response for creating upload");
  //   }

  //   _uploadUrl = Uri.parse(resBody['upload']['upload_link'].toString());
  //   store?.set(_fingerprint, _uploadUrl as Uri);
  // }

  /// Check if possible to resume an already started upload
  // Future<bool> resume() async {
  //   _fileSize = await file.length();
  //   _pauseUpload = false;

  //   // if (!resumingEnabled) {
  //   //   return false;
  //   // }

  //   // _uploadUrl = await store?.get(_fingerprint);

  //   if (uploadUrl == null) {
  //     return false;
  //   }
  //   return true;
  // }

  /// Start or resume an upload in chunks of [maxChunkSize] throwing
  /// [ProtocolException] on server error
  upload({
    Function(double)? onProgress,
    Function()? onComplete,
  }) async {
    // if (!await resume()) {
    //   //TODO!: if upload already started remove video from vimeo before retrying
    //   await create();
    // }

    _fileSize = await file.length();
    _pauseUpload = false;

    // get offset from server
    _offset = await _getOffset();

    int totalBytes = _fileSize as int;

    // start upload
    final client = getHttpClient();

    while (!_pauseUpload && (_offset ?? 0) < totalBytes) {
      //Checks for internet connectivity first
      if (await InternetConnectionChecker().hasConnection) {
        //Updates request headers
        final uploadHeaders = <String, String>{
          "Tus-Resumable": tusVersion,
          "Upload-Offset": "$_offset",
          "Content-Type": "application/offset+octet-stream"
        };
        //Makes request
        _chunkPatchFuture = client
            .patch(
              uploadUrl,
              headers: uploadHeaders,
              body: await _getData(),
            )
            .timeout(const Duration(seconds: 40));

        try {
          final response = await _chunkPatchFuture;
          _chunkPatchFuture = null;

          //Checks if correctly uploaded
          if (!(response.statusCode >= 200 && response.statusCode < 300)) {
            throw ProtocolException(
                "Unexpected status code (${response.statusCode}) while uploading chunk");
          }

          int? serverOffset = _parseOffset(response.headers["upload-offset"]);
          if (serverOffset == null) {
            throw ProtocolException(
                "Response to PATCH request contains no or invalid upload-offset header");
          }
          if (_offset != serverOffset) {
            throw ProtocolException(
                "Response contains different upload-ffset value ($serverOffset) than expected ($_offset)");
          }

          //Updates progress
          if (onProgress != null) {
            onProgress((_offset ?? 0) / totalBytes * 100);
          }

          if (_offset == totalBytes) {
            this.onComplete();
            if (onComplete != null) {
              onComplete();
            }
          }
        } on TimeoutException catch (e) {
          throw ConnectivityException('Upload request timed out');
        }
      } else {
        //Internet down
        throw ConnectivityException('Internet connection unavailable');
      }
    }
  }

  //Removes patially uploaded video on Vimeo
  abort() {
    //TODO: Implement
  }

  /// Pause the current upload
  pause() {
    _pauseUpload = true;
    _chunkPatchFuture?.timeout(Duration.zero);
  }

  /// Actions to be performed after a successful upload
  void onComplete() {
    // store?.remove(_fingerprint);
  }

  /// Override this method to customize creating file fingerprint
  String? generateFingerprint() {
    return file.path.replaceAll(RegExp(r"\W+"), '.');
  }

  /// Override this to customize creating 'Upload-Metadata'
  String generateMetadata() {
    final meta = Map<String, String>.from(metadata ?? {});

    if (!meta.containsKey("filename")) {
      meta["filename"] = p.basename(file.path);
    }

    return meta.entries
        .map((entry) =>
            entry.key + " " + base64.encode(utf8.encode(entry.value)))
        .join(",");
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
    final client = getHttpClient();

    final offsetHeaders = <String, String>{
      "Tus-Resumable": tusVersion,
      HttpHeaders.acceptHeader: 'application/vnd.vimeo.*+json;version=3.4',
    };
    final response = await client.head(uploadUrl, headers: offsetHeaders);

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      throw ProtocolException(
          "Unexpected status code (${response.statusCode}) while resuming upload");
    }

    int? serverOffset = _parseOffset(response.headers["upload-offset"]);
    if (serverOffset == null) {
      throw ProtocolException(
          "Missing upload offset in response for resuming upload");
    }
    return serverOffset;
  }

  /// Get data from file to upload

  Future<Uint8List> _getData() async {
    int start = _offset ?? 0;
    int end = (_offset ?? 0) + maxChunkSize;
    end = end > (_fileSize ?? 0) ? _fileSize ?? 0 : end;

    final result = BytesBuilder();
    await for (final chunk in file.openRead(start, end)) {
      result.add(chunk);
    }

    final bytesRead = min(maxChunkSize, result.length);
    _offset = (_offset ?? 0) + bytesRead;

    return result.takeBytes();
  }

  int? _parseOffset(String? offset) {
    if (offset == null || offset.isEmpty) {
      return null;
    }
    if (offset.contains(",")) {
      offset = offset.substring(0, offset.indexOf(","));
    }
    return int.tryParse(offset);
  }
}
