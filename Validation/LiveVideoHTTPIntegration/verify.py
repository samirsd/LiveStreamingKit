#!/usr/bin/env python3
"""Verify a synthetic Swift recording against an isolated loopback Django server.

Credentials and signed media addresses stay in memory. Only sanitized metadata,
generated media, and a rewritten local playlist are written to the run directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import urljoin, urlsplit, urlunsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler


class ProbeFailure(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def main():
    arguments = argparse.ArgumentParser()
    arguments.add_argument('--credentials', required=True)
    arguments.add_argument('--capture', required=True)
    args = arguments.parse_args()
    capture_path = Path(args.capture).resolve()
    capture = json.loads(capture_path.read_text())
    credentials = json.loads(Path(args.credentials).read_text())
    origin = urlsplit(credentials['base_url'])
    if origin.scheme != 'http' or origin.hostname not in ('127.0.0.1', 'localhost', '::1'):
        raise ProbeFailure('loopback_required')
    opener = build_opener(ProxyHandler({}), NoRedirect())
    statuses = {}
    phase = 'grant'
    output = capture_path.parent

    def safe_url(value, relative_to=credentials['base_url']):
        resolved = urljoin(relative_to, value)
        parsed = urlsplit(resolved)
        if (parsed.scheme, parsed.hostname, parsed.port) != (origin.scheme, origin.hostname, origin.port) or parsed.username or parsed.password or parsed.fragment:
            raise ProbeFailure('non_loopback_media')
        return resolved

    def get(value, *, authenticated=False, label='media', relative_to=credentials['base_url']):
        headers = {'Accept': '*/*'}
        if authenticated:
            headers['Authorization'] = f"Bearer {credentials['token']}"
        request = Request(safe_url(value, relative_to), headers=headers)
        try:
            with opener.open(request, timeout=20) as response:
                data, status = response.read(), response.status
        except HTTPError as error:
            data, status = b'', error.code
        statuses[label] = status
        return data, status

    def successful(value, **kwargs):
        body, status = get(value, **kwargs)
        if status != 200:
            raise ProbeFailure(f'http_{status}')
        return body

    def unsigned(value):
        parsed = urlsplit(safe_url(value))
        return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, '', ''))

    def probe(path):
        program = shutil.which('ffprobe')
        if not program:
            raise ProbeFailure('ffprobe_missing')
        result = subprocess.run([program, '-v', 'error', '-count_frames', '-show_streams', '-show_format', '-of', 'json', str(path)], capture_output=True)
        if result.returncode:
            raise ProbeFailure('ffprobe_failed')
        source = json.loads(result.stdout)
        fields = ('codec_type', 'codec_name', 'width', 'height', 'channels', 'sample_rate', 'start_time', 'duration', 'avg_frame_rate', 'nb_read_frames')
        streams = [{key: stream[key] for key in fields if key in stream} for stream in source['streams']]
        video = next(stream for stream in streams if stream['codec_type'] == 'video')
        audio = next(stream for stream in streams if stream['codec_type'] == 'audio')
        if video['codec_name'] != 'h264' or (video['width'], video['height']) != (720, 1280):
            raise ProbeFailure('portrait_video_mismatch')
        if int(video.get('nb_read_frames', 0)) != capture['seconds'] * capture['frames_per_second']:
            raise ProbeFailure('video_frame_count_mismatch')
        if audio['codec_name'] != 'aac' or audio['channels'] != 2 or audio['sample_rate'] != '48000':
            raise ProbeFailure('stereo_audio_mismatch')
        duration = float(source['format']['duration'])
        if abs(duration - capture['seconds']) > 0.35:
            raise ProbeFailure('duration_mismatch')
        offset = abs(float(video.get('start_time', 0)) - float(audio.get('start_time', 0)))
        if offset > 0.15:
            raise ProbeFailure('av_start_offset')
        decoder = shutil.which('ffmpeg')
        if not decoder:
            raise ProbeFailure('ffmpeg_missing')
        decoded = subprocess.run([decoder, '-v', 'error', '-i', str(path), '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'], capture_output=True)
        if decoded.returncode or decoded.stderr.strip():
            raise ProbeFailure('decode_failed')
        return {'streams': streams, 'duration_seconds': duration, 'av_start_offset_seconds': offset, 'decoded_both_tracks': True}

    try:
        if capture.get('passed') is not True:
            raise ProbeFailure('capture_not_passed')
        session_id = capture['session_id']
        if not re.fullmatch(r'[A-Za-z0-9_-]+', session_id):
            raise ProbeFailure('invalid_session_id')
        session_path = f'/api/v1/livestream/sessions/{session_id}/'
        _, guest_grant = get(session_path + 'playback/', label='guest_grant')
        if guest_grant not in (401, 403):
            raise ProbeFailure('guest_grant_not_denied')
        grant = json.loads(successful(session_path + 'playback/', authenticated=True, label='authorized_grant'))
        master_url = safe_url(grant['master_playlist_url'])
        _, denied_master = get(unsigned(master_url), label='unsigned_master')
        if denied_master not in (401, 403):
            raise ProbeFailure('unsigned_master_not_denied')
        master = successful(master_url, label='authorized_master').decode()
        renditions = [line.strip() for line in master.splitlines() if line.strip() and not line.startswith('#')]
        if '#EXTM3U' not in master or len(renditions) != 1:
            raise ProbeFailure('unexpected_master')
        media_url = safe_url(renditions[0], master_url)
        phase = 'media_download'
        _, denied_media = get(unsigned(media_url), label='unsigned_media_playlist')
        if denied_media not in (401, 403):
            raise ProbeFailure('unsigned_media_playlist_not_denied')
        playlist = successful(media_url, label='authorized_media_playlist').decode()
        if '#EXT-X-ENDLIST' not in playlist:
            raise ProbeFailure('replay_not_finalized')
        initialization = re.search(r'#EXT-X-MAP:URI="([^"]+)"', playlist)
        if not initialization:
            raise ProbeFailure('missing_initialization')
        init_url = safe_url(initialization.group(1), media_url)
        _, denied_init = get(unsigned(init_url), label='unsigned_initialization')
        if denied_init not in (401, 403):
            raise ProbeFailure('unsigned_initialization_not_denied')
        local = output / 'listener-download'
        local.mkdir(exist_ok=False)
        initialization_bytes = successful(init_url, label='authorized_initialization')
        if initialization_bytes != (Path(capture['archive_directory']) / 'init.mp4').read_bytes():
            raise ProbeFailure('initialization_bytes_mismatch')
        (local / 'init.mp4').write_bytes(initialization_bytes)
        rewritten = []
        downloaded = []
        sequence = 0
        allowed_tags = ('#EXTM3U', '#EXT-X-VERSION:', '#EXT-X-TARGETDURATION:', '#EXT-X-MEDIA-SEQUENCE:',
                        '#EXT-X-PLAYLIST-TYPE:', '#EXT-X-INDEPENDENT-SEGMENTS', '#EXTINF:', '#EXT-X-ENDLIST')
        for line in playlist.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith('#EXT-X-MAP:'):
                rewritten.append('#EXT-X-MAP:URI="init.mp4"')
            elif line.startswith('#'):
                if line.startswith(allowed_tags) and 'URI=' not in line:
                    rewritten.append(line)
            else:
                segment_url = safe_url(line, media_url)
                if sequence == 0:
                    _, denied_segment = get(unsigned(segment_url), label='unsigned_segment')
                    if denied_segment not in (401, 403):
                        raise ProbeFailure('unsigned_segment_not_denied')
                name = f'segment-{sequence:06}.m4s'
                body = successful(segment_url, label='authorized_segment')
                if body != (Path(capture['archive_directory']) / name).read_bytes():
                    raise ProbeFailure('segment_bytes_mismatch')
                (local / name).write_bytes(body)
                downloaded.append({'file': name, 'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()})
                rewritten.append(name)
                sequence += 1
        if sequence != capture['events']['segments_delivered']:
            raise ProbeFailure('published_segment_count_mismatch')
        (local / 'index.m3u8').write_text('\n'.join(rewritten) + '\n')
        phase = 'decode'
        hls = probe(local / 'index.m3u8')
        exported = probe(Path(capture['export_file']))
        phase = 'final_status'
        metadata = json.loads(successful(session_path, label='session_status'))
        if (metadata['status'] != 'ended' or metadata.get('media_type') != 'video' or not metadata.get('has_audio')
                or metadata.get('codec') != 'h264-aac-fmp4'
                or (metadata.get('video_width'), metadata.get('video_height'), metadata.get('video_frame_rate')) != (720, 1280, 30)):
            raise ProbeFailure('final_session_metadata')
        summary = {'passed': True, 'synthetic_only': True, 'loopback_only': True,
                   'session_id': session_id, 'session_status': metadata['status'], 'segments_downloaded': sequence,
                   'status_codes': statuses, 'hls': hls, 'mp4_export': exported, 'downloaded_segments': downloaded,
                   'media_refresh_after_seconds': grant.get('media_url_refresh_after_seconds'), 'download_matches_local_archive': True}
        (output / 'verification.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
        print(f'Protected playback and both-track decoding passed. Evidence: {output / "verification.json"}')
    except Exception as error:
        (output / 'verification-failure.json').write_text(json.dumps({'passed': False, 'phase': phase, 'error_type': type(error).__name__,
                                                                  'error_code': str(error) if isinstance(error, ProbeFailure) else 'unexpected',
                                                                  'status_codes': statuses}, indent=2) + '\n')
        print(f'Listener verification failed during {phase}; consult sanitized evidence.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Listener verification could not initialize; no credential details emitted.', file=sys.stderr)
        sys.exit(1)
