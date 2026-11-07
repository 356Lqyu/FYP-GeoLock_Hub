// Shared state for the hub admin tabs.
import 'package:flutter/foundation.dart';

import 'hub_service.dart';

enum HubAdminTab { dashboard, dropOffs, inventory, listings, profile }

class HubAdminController extends ChangeNotifier {
  HubSummary _hub;
  int _dataVersion = 0;
  int _unreadCount = 0;
  int _awaitingCount = 0;
  String? _inventoryCategory;
  void Function(HubAdminTab tab)? _openTab;

  HubAdminController(this._hub);

  HubSummary get hub => _hub;
  String get hubId => _hub.id;

  /// Changes whenever data may be out of date; pages reload when it changes.
  int get dataVersion => _dataVersion;

  int get unreadCount => _unreadCount;
  int get awaitingCount => _awaitingCount;

  /// Category to preselect when the inventory tab opens (from the dashboard).
  String? takeInventoryCategory() {
    final category = _inventoryCategory;
    _inventoryCategory = null;
    return category;
  }

  set hub(HubSummary value) {
    if (value.id == _hub.id) {
      _hub = value; // same hub, fresh details (e.g. after editing the name)
      return;
    }
    _hub = value;
    _unreadCount = 0;
    _awaitingCount = 0;
    _dataVersion++;
    notifyListeners();
  }

  /// Call after any write (receipt, batch, rules) so every tab reloads.
  void dataChanged() {
    _dataVersion++;
    notifyListeners();
  }

  set unreadCount(int value) {
    if (value == _unreadCount) return;
    _unreadCount = value;
    notifyListeners();
  }

  set awaitingCount(int value) {
    if (value == _awaitingCount) return;
    _awaitingCount = value;
    notifyListeners();
  }

  void attachTabOpener(void Function(HubAdminTab tab)? opener) =>
      _openTab = opener;

  void openTab(HubAdminTab tab, {String? inventoryCategory}) {
    _inventoryCategory = inventoryCategory;
    _openTab?.call(tab);
    if (inventoryCategory != null) notifyListeners();
  }
}

/// Reloads a tab when the hub or the data version changes.
mixin HubReloadOnChange {
  int _seenVersion = -1;
  String? _seenHub;

  /// True when [controller] moved on since the last call.
  bool hubNeedsReload(HubAdminController controller) {
    final changed =
        controller.dataVersion != _seenVersion || controller.hubId != _seenHub;
    _seenVersion = controller.dataVersion;
    _seenHub = controller.hubId;
    return changed;
  }
}
