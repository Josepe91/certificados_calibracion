import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Inicio de sesión de los técnicos con su cuenta de Google.
///
/// Reemplaza la auth anónima: con ella cualquiera que tuviera el APK (o
/// solo la configuración de Firebase que va dentro) podía leer, editar o
/// borrar todo el inventario. Ahora las reglas de Firestore/Storage
/// (firestore.rules, storage.rules) solo dejan entrar a los correos de
/// [tecnicos], y solo [admin] puede marcar un certificado como montado
/// (ver MontajesSync). La lista de aquí es solo para dar un mensaje claro
/// en la app; quien de verdad bloquea son las reglas — si se agrega un
/// técnico hay que agregarlo en los dos lados.
class AuthTecnico {
  AuthTecnico._();

  static const admin = 'sebasperez1691@gmail.com';

  static const tecnicos = {
    admin,
    'direcciontecnica.btm@gmail.com',
    'biomedico.btm@gmail.com',
    'forero2701@gmail.com',
  };

  static final GoogleSignIn _google = GoogleSignIn(scopes: ['email']);

  static User? get usuario => FirebaseAuth.instance.currentUser;

  static String get correo => usuario?.email?.toLowerCase() ?? '';

  /// Sesión válida: cuenta de Google (no anónima) de un técnico autorizado.
  static bool get autorizado =>
      usuario != null && !usuario!.isAnonymous && tecnicos.contains(correo);

  static bool get esAdmin => autorizado && correo == admin;

  /// Nombre para firmar acciones (montado, historial): el de la cuenta de
  /// Google, o el correo si la cuenta no tiene nombre.
  static String get nombre {
    final n = usuario?.displayName?.trim() ?? '';
    return n.isNotEmpty ? n : correo;
  }

  /// Reemplaza el antiguo `_asegurarSesion` (que entraba anónimo): sin una
  /// sesión autorizada no se intenta nada contra la nube. Lanza en vez de
  /// devolver false para que cada llamador siga usando su mismo
  /// try/catch de "sin conexión, se sigue trabajando local".
  static Future<void> asegurarSesion() async {
    if (!autorizado) throw StateError('Sin sesión de técnico autorizado');
  }

  /// Abre el selector de cuentas de Google. Retorna null si quedó adentro,
  /// o el mensaje a mostrar si se canceló o la cuenta no está autorizada.
  static Future<String?> iniciarSesion() async {
    try {
      // Siempre mostrar el selector, para poder elegir otra cuenta si la
      // primera no estaba autorizada.
      await _google.signOut();
      final cuenta = await _google.signIn();
      if (cuenta == null) return 'Inicio de sesión cancelado';

      if (!tecnicos.contains(cuenta.email.toLowerCase())) {
        await _google.signOut();
        return 'La cuenta ${cuenta.email} no está autorizada.\n'
            'Pídele a Sebastián que la agregue.';
      }

      final tokens = await cuenta.authentication;
      final credencial = GoogleAuthProvider.credential(
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      final actual = usuario;
      if (actual != null && actual.isAnonymous) {
        // La sesión anónima de versiones anteriores no tiene nada propio
        // que conservar (todo vive bajo clientes/, no bajo el uid).
        await FirebaseAuth.instance.signOut();
      }
      await FirebaseAuth.instance.signInWithCredential(credencial);
      return null;
    } on FirebaseAuthException catch (e) {
      return 'No se pudo iniciar sesión (${e.code}). Revisa el internet.';
    } catch (e) {
      return 'No se pudo iniciar sesión. Revisa el internet.\n($e)';
    }
  }

  static Future<void> cerrarSesion() async {
    await _google.signOut();
    await FirebaseAuth.instance.signOut();
  }
}
