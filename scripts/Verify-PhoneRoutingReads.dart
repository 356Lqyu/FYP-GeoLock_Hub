// Operator-authorized read-only checks through the existing debug NGO session.
// No JWT is extracted, printed, persisted or sent outside the existing clients.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  const adb = 'C:/Users/User/AppData/Local/Android/Sdk/platform-tools/adb.exe';
  const owner = '8e50bc66-7a8d-4791-bc6b-640682daa496';
  const request = '20a8b059-63fc-40b6-bea9-0751ef1a199b';
  final marker =
      'GEOLOCK_READONLY_RECEIPT_${DateTime.now().microsecondsSinceEpoch}';
  String phase = 'device';
  String? localPort;
  WebSocket? socket;
  final pending = <String, Completer<Map<String, dynamic>>>{};
  var seq = 0;
  try {
    final process = await Process.run(adb, [
      'shell',
      'pidof',
      'com.example.geolock_hub_app',
    ]);
    final pid = (process.stdout as String).trim();
    if (process.exitCode != 0 || !RegExp(r'^\d+$').hasMatch(pid))
      throw StateError('App must be open');
    final logs = await Process.run(adb, [
      'logcat',
      '-d',
      '--pid=$pid',
      '-s',
      'flutter',
    ]);
    final matches = RegExp(
      r'Dart VM service is listening on (http://127\.0\.0\.1:(\d+)/[^\s]+)',
    ).allMatches(logs.stdout as String).toList();
    if (matches.isEmpty) throw StateError('No debug VM');
    final service = Uri.parse(matches.last.group(1)!);
    phase = 'debug_forward';
    final forward = await Process.run(adb, [
      'forward',
      'tcp:0',
      'tcp:${service.port}',
    ]);
    if (forward.exitCode != 0) throw StateError('Forward unavailable');
    localPort = (forward.stdout as String).trim();
    phase = 'debug_connect';
    // The VM access URI remains in memory; never print errors/URLs from it.
    socket = await WebSocket.connect(
      service
          .replace(
            scheme: 'ws',
            port: int.parse(localPort),
            path: '${service.path}ws',
          )
          .toString(),
    ).timeout(const Duration(seconds: 8));
    socket.listen((raw) {
      final data = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      if (data['id'] != null)
        pending.remove(data['id'].toString())?.complete(data);
    });
    Future<Map<String, dynamic>> rpc(
      String name,
      Map<String, dynamic> args,
    ) async {
      final id = '${++seq}', c = Completer<Map<String, dynamic>>();
      pending[id] = c;
      socket!.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': name,
          'params': args,
        }),
      );
      final response = await c.future.timeout(const Duration(seconds: 10));
      if (response['error'] != null) {
        final error = response['error'] as Map;
        final detail = '${error['data'] ?? ''}';
        stdout.writeln(
          jsonEncode({
            'debug_rpc': name,
            'error_code': error['code'],
            'compiler_markers': [
              for (final label in [
                'Supabase',
                'RoutingWorkerClient',
                'jsonEncode',
                'async',
                'disableBreakpoints',
                'Compilation',
                'not found',
              ])
                if (detail.contains(label)) label,
            ],
          }),
        );
        for (final line
            in detail.split('\n').where((line) => line.contains('Error:'))) {
          final message = line.substring(line.indexOf('Error:'));
          if (!message.contains('http') && !message.contains('Bearer'))
            stdout.writeln(
              message.length > 240 ? message.substring(0, 240) : message,
            );
        }
        throw StateError('Debug RPC rejected');
      }
      return Map<String, dynamic>.from(response['result'] as Map);
    }

    phase = 'debug_library';
    final vm = await rpc('getVM', {});
    final isolate = (vm['isolates'] as List).firstWhere(
      (i) => i['name'] == 'main',
    )['id'];
    final info = await rpc('getIsolate', {'isolateId': isolate});
    final library = (info['libraries'] as List).firstWhere(
      (l) =>
          (l['uri'] as String).endsWith('/routing/ngo_routing_repository.dart'),
    )['id'];
    phase = 'readonly_session_checks';
    final inventoryRead = arguments.contains('--inventory')
        ? '''
        final cards=await client.rpc('get_my_claim_cards_v2');
        final fleet=await client.rpc('list_my_vehicles');
        final overview=await client.rpc('get_my_routing_overview');
        final locations=[];
        for(final card in cards) {
          if(card['claim_status']=='ACTIVE' && card['task_status']=='CONFIRMED') {
            Map d={}; try { d=Map.from(await client.rpc('get_claimed_listing_detail',params:{'p_claim':card['claim_id']})); } catch(e) { d={'location_read_error':e.runtimeType.toString()}; }
            locations.add({'claim_id':card['claim_id'],'pickup_address':d['pickup_address'],'pickup_latitude':d['pickup_latitude'],'pickup_longitude':d['pickup_longitude'],'pickup_road_node_id':d['pickup_road_node_id'],'location_read_error':d['location_read_error']});
          }
        }
        final inventoryJson=jsonEncode({'claims':cards.map((c)=>{'claim_id':c['claim_id'],'listing_id':c['listing_id'],'title':c['title'],'weight_kg':c['listing_weight_kg'],'claim_status':c['claim_status'],'lease_status':c['lease_status'],'lease_expires_at':c['lease_expires_at'],'task_status':c['task_status'],'server_now':c['server_now'],'lease_recovery_pending':c['lease_recovery_pending']}).toList(),'fleet':fleet,'overview':overview,'locations':locations}); for(var offset=0;offset<inventoryJson.length;offset+=650) { final end=offset+650<inventoryJson.length?offset+650:inventoryJson.length; print('$marker INVENTORY_CHUNK '+offset.toString()+':'+inventoryJson.substring(offset,end)); }
    '''
        : '';
    final expression =
        '''(() async {
      final client=Supabase.instance.client;
      if(client.auth.currentUser?.id!='$owner') { print('$marker WRONG_OWNER'); return; }
      try {
        $inventoryRead
        ${arguments.contains('--inventory-only') ? "print('$marker INVENTORY_DONE'); return;" : ''}
        final r=await client.rpc('get_my_routing_authorization_receipt',params:{'p_request':'$request'});
        print('$marker POSTGREST '+jsonEncode({'contract':r['contract'],'ngo_id':r['ngo_id'],'request_id':r['request_id'],'outcome':r['outcome']}));
        if(client.auth.currentUser?.id!='$owner') { print('$marker ACCOUNT_CHANGED');return; }
        final w=RoutingWorkerClient(baseUrl:'http://127.0.0.1:8787',accessToken:()=>client.auth.currentSession?.accessToken);
        final c=await w.authorizationCapabilities({'request_id':'$request'});
        print('$marker CAPABILITY '+jsonEncode(c));
      } catch(e) { print('$marker FAILED '+e.runtimeType.toString()); }
    })()''';
    // The VM expression compiler expects a single expression line.
    final singleLine = expression.replaceAll('\r', ' ').replaceAll('\n', ' ');
    await rpc('evaluate', {
      'isolateId': isolate,
      'targetId': library,
      'expression': singleLine,
      'disableBreakpoints': true,
    });
    // Bounded observation only: no retry of either authenticated read.
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final seen = await Process.run(adb, [
        'logcat',
        '-d',
        '--pid=$pid',
        '-s',
        'flutter',
      ]);
      final lines = (seen.stdout as String)
          .split('\n')
          .where((l) => l.contains('$marker '))
          .map((l) => l.substring(l.indexOf(marker)).trimRight())
          .toList();
      if (lines.any(
        (l) =>
            l.contains(' INVENTORY_DONE') ||
            l.contains(' CAPABILITY ') ||
            l.contains(' FAILED ') ||
            l.contains('WRONG_OWNER') ||
            l.contains('ACCOUNT_CHANGED'),
      )) {
        final chunks = lines
            .where((line) => line.contains(' INVENTORY_CHUNK '))
            .toList();
        if (chunks.isNotEmpty) {
          final joined = chunks.map((line) {
            final part = line.substring(line.indexOf(' INVENTORY_CHUNK ') + 17);
            return part.substring(part.indexOf(':') + 1);
          }).join();
          jsonDecode(
            joined,
          ); // Fail closed if log transport dropped/truncated a chunk.
          stdout.writeln('$marker INVENTORY ' + joined);
        }
        for (final line in lines.where(
          (line) => !line.contains(' INVENTORY_CHUNK '),
        )) {
          stdout.writeln(line);
        }
        exitCode =
            lines.any(
              (l) =>
                  l.contains(' CAPABILITY ') || l.contains(' INVENTORY_DONE'),
            )
            ? 0
            : 1;
        return;
      }
    }
    throw TimeoutException('Bounded observation ended');
  } catch (e) {
    stdout.writeln(
      jsonEncode({
        'status': 'NOT_VERIFIED',
        'phase': phase,
        'exception_type': e.runtimeType.toString(),
        'database_writes': false,
      }),
    );
    exitCode = 1;
  } finally {
    await socket?.close();
    if (localPort != null)
      await Process.run(adb, ['forward', '--remove', 'tcp:$localPort']);
  }
}
