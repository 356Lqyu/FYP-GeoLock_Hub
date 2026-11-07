import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class ClaimPickupDetailReader {
  String? get identity;

  Future<Object?> rpc(String name, {Map<String, dynamic>? params});
}

class SupabaseClaimPickupDetailReader implements ClaimPickupDetailReader {
  const SupabaseClaimPickupDetailReader(this.client);

  final SupabaseClient client;

  @override
  String? get identity => client.auth.currentUser?.id;

  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) =>
      client.rpc(name, params: params);
}
