'use strict';

// Safari delivers SFSafariApplication.dispatchMessage replies to the native port as
// { name, userInfo }, and follows each request with an empty message. client.js expects
// the bare KeePassXC reply, so unwrap userInfo and drop anything that is not an object.
(function () {
    const handle = keepassClient.onNativeMessage;
    keepassClient.onNativeMessage = function (message) {
        if (!message || typeof message !== 'object') {
            return;
        }
        const reply = message.userInfo;
        handle(reply && typeof reply === 'object' ? reply : message);
    };
})();
