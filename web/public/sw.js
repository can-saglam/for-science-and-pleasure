self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data?.json() ?? {};
  } catch {
    payload = { body: event.data?.text() ?? "" };
  }

  const {
    title = "Can We Go?",
    body,
    icon = "./icon-192.png",
    badge,
    tag,
    data,
  } = payload;

  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      icon,
      badge,
      tag,
      data,
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const digestId = event.notification.data?.digestId;
  const targetUrl = event.notification.data?.url ?? self.registration.scope;
  const scopePath = new URL(self.registration.scope).pathname;

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const app = windows.find((client) => new URL(client.url).pathname.startsWith(scopePath));
      if (app) {
        return app.focus().then(() => {
          app.postMessage({ type: "OPEN_DIGEST", digestId });
        });
      }
      return self.clients.openWindow(targetUrl);
    }),
  );
});
