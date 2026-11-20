# Abrova Push desktop example

A small app that registers this computer, shows the connection state and lists the pushes and in-app
messages it receives.

```bash
flutter run -d macos   --dart-define=API_KEY=your_api_key
flutter run -d windows --dart-define=API_KEY=your_api_key
flutter run -d linux   --dart-define=API_KEY=your_api_key --dart-define=USER_ID=user-42
```

Then send a push to this computer (or to `USER_ID`) from the Console or your server.
