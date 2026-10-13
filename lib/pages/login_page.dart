import 'package:flutter/material.dart';

import '../data/auth_tecnico.dart';

/// Pantalla de entrada: solo se muestra mientras no haya una sesión de
/// Google de un técnico autorizado (ver AuthTecnico y el gate en main.dart).
/// Se pasa una sola vez por celular; después la sesión queda guardada y
/// funciona sin internet.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _cargando = false;
  String? _error;

  Future<void> _entrar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    final error = await AuthTecnico.iniciarSesion();
    if (!mounted) return;
    setState(() {
      _cargando = false;
      _error = error == 'Inicio de sesión cancelado' ? null : error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 72, color: Colors.blue.shade700),
                const SizedBox(height: 16),
                const Text(
                  'BTMC Certificados',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Entra con tu cuenta de Google de BTMC.\n'
                  'Solo se hace una vez en este celular.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _cargando ? null : _entrar,
                    icon: _cargando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Entrar con Google'),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
