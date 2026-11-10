import { isAbsolute, join } from 'node:path';
import { Socket } from 'node:net';
import { closeSync } from 'node:fs';

// Internal host capability. The directory must come from the native runtime
// publication, never plugin argv/env or a user-selected filesystem grant.
export function loadLinuxNative({ nativeLibraryDirectory }) {
  if (typeof nativeLibraryDirectory !== 'string' || !isAbsolute(nativeLibraryDirectory)) {
    throw Object.assign(new TypeError('A published native library directory is required'), { code: 'ERR_OHOS_LINUX_NATIVE_ROOT' });
  }
  const module = { exports: {} };
  process.dlopen(module, join(nativeLibraryDirectory, 'libdsh_linux.so'));
  return Object.freeze({
    create(config) {
      const owner = module.exports.create(config);
      let socket;
      try { socket = new Socket({ fd: owner.fd, readable: true, writable: true }); }
      catch (cause) {
        try { closeSync(owner.fd); }
        catch (closeError) {
          cause.linuxFdCloseError = closeError;
          // Diagnostic ownership debt, not permission to retry close after EINTR.
          cause.linuxUnsettledFd = owner.fd;
        }
        finally { owner.requestStop(); }
        // Caller must observe this explicit join rather than lose the owner.
        cause.linuxJoin = owner.join(); throw cause;
      }
      return Object.freeze({
        socket,
        requestStop: () => owner.requestStop(),
        join: () => owner.join(),
      });
    },
  });
}
