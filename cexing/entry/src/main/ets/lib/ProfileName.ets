function cleanProfileName(value: string): string {
  const name = value.trim().replace(/\.(yaml|yml)$/i, '');
  if (name.length === 0 || name.length > 80 || name === '.' || name === '..' || /[/\\\x00-\x1f\x7f]/.test(name)) {
    return '';
  }
  return name;
}

export function suggestProfileName(headers: Record<string, Object>, fallback: string): string {
  let disposition = '';
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === 'content-disposition' && typeof headers[key] === 'string') {
      disposition = headers[key] as string;
      break;
    }
  }
  const extended = /filename\*\s*=\s*UTF-8'[^']*'([^;]+)/i.exec(disposition);
  if (extended !== null) {
    try {
      const name = cleanProfileName(decodeURIComponent(extended[1].trim().replace(/^"|"$/g, '')));
      if (name.length > 0) {
        return name;
      }
    } catch (e) {
      // 无效编码时继续尝试普通文件名。
    }
  }
  const basic = /filename\s*=\s*(?:"([^"]*)"|([^;]*))/i.exec(disposition);
  if (basic !== null) {
    const name = cleanProfileName(basic[1] !== undefined ? basic[1] : basic[2]);
    if (name.length > 0) {
      return name;
    }
  }
  return fallback;
}
