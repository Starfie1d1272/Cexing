/* Bounded asynchronous picker I/O. No truncated YAML or leaked picker fd.
 * All limits count UTF-8 bytes, matching the 16 MiB core boundary. Imported
 * sources reserve 1 MiB for generated fields; generated output is checked again.
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export const CORE_CONFIG_BYTES: number = 16 * 1024 * 1024;
export const IMPORT_CONFIG_BYTES: number = CORE_CONFIG_BYTES - 1024 * 1024;
const CHUNK_BYTES: number = 64 * 1024;

export namespace BoundedFileReader {
  function check(current?: () => boolean): void {
    if (current !== undefined && !current()) { throw new Error('导入已取消'); }
  }

  export async function bytes(uri: string, limit: number, current?: () => boolean,
    exact?: number): Promise<ArrayBuffer> {
    check(current);
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      check(current);
      const size = (await fileIo.stat(file.fd)).size;
      if (!Number.isSafeInteger(size) || size < 0 || size > limit ||
        (exact !== undefined && size !== exact)) { throw new Error('文件大小不符或超过上限'); }
      const output = new Uint8Array(size);
      let offset = 0;
      while (offset < size) {
        check(current);
        const chunk = new ArrayBuffer(Math.min(CHUNK_BYTES, size - offset));
        const count = await fileIo.read(file.fd, chunk, { offset: offset });
        check(current);
        if (count <= 0 || count > chunk.byteLength) { throw new Error('文件未完整读取'); }
        output.set(new Uint8Array(chunk, 0, count), offset);
        offset += count;
      }
      if (await fileIo.read(file.fd, new ArrayBuffer(1), { offset: size }) !== 0 ||
        (await fileIo.stat(file.fd)).size !== size) { throw new Error('读取时文件已变化'); }
      check(current);
      return output.buffer as ArrayBuffer;
    } finally { await fileIo.close(file); }
  }

  export async function write(uri: string, data: ArrayBuffer, current?: () => boolean): Promise<void> {
    check(current);
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < data.byteLength) {
        check(current);
        const chunk = data.slice(offset, Math.min(offset + CHUNK_BYTES, data.byteLength));
        const count = await fileIo.write(file.fd, chunk, { offset: offset });
        if (count <= 0 || count > chunk.byteLength) { throw new Error('文件未完整写入'); }
        offset += count;
      }
      await fileIo.fsync(file.fd); check(current);
    } finally { await fileIo.close(file); }
  }

  export async function yaml(uri: string, current?: () => boolean): Promise<string> {
    const data = await bytes(uri, IMPORT_CONFIG_BYTES, current);
    return await decodeUtf8(data, current);
  }

  export async function decodeUtf8(data: ArrayBuffer, current?: () => boolean, start: number = 0): Promise<string> {
    check(current);
    const decoder = util.TextDecoder.create('utf-8', { fatal: true });
    const parts: string[] = [];
    for (let offset = start; offset < data.byteLength; offset += CHUNK_BYTES) {
      check(current);
      parts.push(decoder.decodeToString(new Uint8Array(data, offset,
        Math.min(CHUNK_BYTES, data.byteLength - offset)), { stream: true }));
      // Yield between bounded decoding batches, including while the picker page exits.
      await new Promise<void>((resolve) => { setTimeout(resolve, 0); });
    }
    parts.push(decoder.decodeToString(new Uint8Array(0)));
    check(current);
    return parts.join('');
  }

  export function checkConfigSize(content: string): void {
    // Avoid constructing another full byte buffer just to count UTF-8 bytes.
    let size = 0;
    for (let i = 0; i < content.length; i++) {
      const c = content.charCodeAt(i);
      if (c < 0x80) { size++; }
      else if (c < 0x800) { size += 2; }
      else if (c >= 0xd800 && c <= 0xdbff) {
        const low = content.charCodeAt(++i);
        if (!(low >= 0xdc00 && low <= 0xdfff)) { throw new Error('配置编码无效'); }
        size += 4;
      } else if (c >= 0xdc00 && c <= 0xdfff) { throw new Error('配置编码无效'); }
      else { size += 3; }
      if (size > IMPORT_CONFIG_BYTES) { throw new Error('配置超过 15 MiB 上限'); }
    }
  }
}
