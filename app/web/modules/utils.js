export function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function parentPath(value) {
  return String(value || "").replace(/[\\/][^\\/]+$/, "");
}

export function formatWorkflowTime(value) {
  if (!value) {
    return "";
  }
  const match = String(value).match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/);
  return match ? `${match[1]} ${match[2]}` : String(value);
}
