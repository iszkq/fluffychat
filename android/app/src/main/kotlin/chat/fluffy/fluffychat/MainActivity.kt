package chat.fluffy.fluffychat

import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint

import android.content.Context

class MainActivity : FlutterFragmentActivity() {

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // do nothing, because the engine was been configured in provideEngine
    }

    // Retain the engine when the back button closes the Flutter fragment.
    override fun createFlutterFragment(): FlutterFragment =
        super.createFlutterFragment().apply {
            arguments?.putBoolean("destroy_engine_with_fragment", false)
        }

    companion object {
        var engine: FlutterEngine? = null
        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context.applicationContext, emptyArray(), true, false)
            engine = eng
            return eng
        }

        fun provideRunningEngine(context: Context): FlutterEngine {
            val eng = provideEngine(context)
            if (!eng.dartExecutor.isExecutingDart) {
                eng.localizationPlugin.sendLocalesToFlutter(context.resources.configuration)
                eng.dartExecutor.executeDartEntrypoint(DartEntrypoint.createDefault())
            }
            return eng
        }
    }
}
