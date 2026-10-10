package chat.fluffy.fluffychat

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

// Share the application's engine so push handling does not open a second database isolate.
class UnifiedPushService : org.unifiedpush.flutter.connector.UnifiedPushService() {
    override fun getEngine(context: Context): FlutterEngine {
        return MainActivity.provideRunningEngine(applicationContext)
    }
}
