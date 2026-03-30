const RESOURCE_SERVER_BASE_URL = "http://127.0.0.1:19420";
const PLAYBACK_POSITION_KEY_PREFIX = "textlingo_video_position_";

export function buildMediaResourceUrl(
  mediaPath: string | undefined,
  resourceType: "video" | "book" = "video",
): string {
  if (!mediaPath) {
    return "";
  }

  if (mediaPath.startsWith("http://") || mediaPath.startsWith("https://")) {
    return mediaPath;
  }

  const filename = mediaPath.split(/[/\\]/).pop();
  if (!filename) {
    return mediaPath;
  }

  return `${RESOURCE_SERVER_BASE_URL}/${resourceType}/${encodeURIComponent(filename)}`;
}

export function buildPlaybackPositionKey(articleId: string | undefined, mediaUrl: string): string {
  return `${PLAYBACK_POSITION_KEY_PREFIX}${articleId || mediaUrl}`;
}
