// Hub models and every hub database call.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../supabase_config.dart';

const hubRankingApiUrl = String.fromEnvironment('GEOLOCK_AI_URL');
const hostedRankingApiUrl = 'https://geolock-hub-ranking.onrender.com';
const _localRankingApis = ['http://127.0.0.1:8000', 'http://10.0.2.2:8000'];

// Models

double hubDouble(Object? value) => double.tryParse('${value ?? ''}') ?? 0;

int hubInt(Object? value) => int.tryParse('${value ?? ''}') ?? 0;

DateTime? hubDate(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();

String? hubText(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

List<Map<String, dynamic>> hubRows(Object? response) => response is List
    ? response.map((row) => Map<String, dynamic>.from(row as Map)).toList()
    : throw const FormatException('The hub service returned an invalid list.');

Map<String, dynamic> hubObject(Object? response) => response is Map
    ? Map<String, dynamic>.from(response)
    : throw const FormatException(
        'The hub service returned an invalid object.',
      );

// Opening hours: {"mon": [{"open": "09:00", "close": "17:00"}], ...} in Malaysia time.
// "24:00" means midnight.

const hubWeekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const hubWeekdayLabels = {
  'mon': 'Monday',
  'tue': 'Tuesday',
  'wed': 'Wednesday',
  'thu': 'Thursday',
  'fri': 'Friday',
  'sat': 'Saturday',
  'sun': 'Sunday',
};

final _hhmm = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

int hubMinutesOf(String hhmm) {
  final parts = hhmm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

/// "09:00" -> "9:00 AM", "13:30" -> "1:30 PM", "24:00" -> "Midnight".
String hubTimeLabel(String hhmm) {
  if (hhmm == '24:00') return 'Midnight';
  final minutes = hubMinutesOf(hhmm);
  final hour = minutes ~/ 60;
  final hour12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$hour12:${(minutes % 60).toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}';
}

/// Malaysia time (UTC+8) now, whatever the phone's time zone.
DateTime hubMalaysiaNow() =>
    DateTime.now().toUtc().add(const Duration(hours: 8));

/// Weekday key of today in Malaysia time, e.g. "mon".
String hubTodayKey() => hubWeekdays[hubMalaysiaNow().weekday - 1];

// Drop-off day: the donor picks the day (today up to 6 days ahead) and can come at any
// time the hub is open that day. Days are plain dates in Malaysia time.

/// Today's date in Malaysia time.
DateTime hubToday() {
  final now = hubMalaysiaNow();
  return DateTime.utc(now.year, now.month, now.day);
}

/// The days a donor can choose: today and the next 6 days.
List<DateTime> hubDropOffDays() =>
    [for (var i = 0; i < 7; i++) hubToday().add(Duration(days: i))];

/// Weekday key of a date, e.g. "mon".
String hubDayKey(DateTime day) => hubWeekdays[day.weekday - 1];

/// "2026-11-04" for the database.
String hubIsoDate(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

/// A date from the database ("2026-11-04"), or null.
DateTime? hubParseDay(Object? value) {
  final parsed = DateTime.tryParse('${value ?? ''}');
  return parsed == null ? null : DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// The drop-off day of a booking: the day of its closing time (a midnight close counts
/// for the day before).
DateTime? hubDropOffDayOf(DateTime? expiresAt) {
  if (expiresAt == null) return null;
  final myt = expiresAt.toUtc().add(const Duration(hours: 8)).subtract(const Duration(seconds: 1));
  return DateTime.utc(myt.year, myt.month, myt.day);
}

/// A closing time in Malaysia time, e.g. "5:00 PM" or "Midnight".
String hubCloseLabel(DateTime? time) {
  if (time == null) return '—';
  final myt = time.toUtc().add(const Duration(hours: 8));
  if (myt.hour == 0 && myt.minute == 0) return 'Midnight';
  return hubTimeLabel(
    '${myt.hour.toString().padLeft(2, '0')}:${myt.minute.toString().padLeft(2, '0')}',
  );
}

const _shortDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Wed 4 Nov".
String hubDayDate(DateTime day) =>
    '${_shortDays[day.weekday - 1]} ${day.day} ${_shortMonths[day.month - 1]}';

/// "Today", "Tomorrow" or "Wed 4 Nov".
String hubDayLabel(DateTime day) {
  final diff = day.difference(hubToday()).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  return hubDayDate(day);
}

/// "today", "tomorrow" or "on Wed 4 Nov", for use inside a sentence.
String hubOnDay(DateTime day) {
  final diff = day.difference(hubToday()).inDays;
  if (diff == 0) return 'today';
  if (diff == 1) return 'tomorrow';
  return 'on ${hubDayDate(day)}';
}

class HubTimeSlot {
  final String open;
  final String close;
  const HubTimeSlot(this.open, this.close);

  Map<String, String> toJson() => {'open': open, 'close': close};
  String get label => '${hubTimeLabel(open)} – ${hubTimeLabel(close)}';
  int get openMinute => hubMinutesOf(open);
  int get closeMinute => close == '24:00' ? 24 * 60 : hubMinutesOf(close);
}

class HubOperatingHours {
  final Map<String, List<HubTimeSlot>> days;
  HubOperatingHours(this.days);

  factory HubOperatingHours.fromJson(Object? json) {
    final days = {for (final d in hubWeekdays) d: <HubTimeSlot>[]};
    if (json is Map) {
      for (final day in hubWeekdays) {
        final list = json[day];
        if (list is! List) continue;
        for (final slot in list) {
          if (slot is Map && slot['open'] != null && slot['close'] != null) {
            days[day]!.add(
              HubTimeSlot(slot['open'].toString(), slot['close'].toString()),
            );
          }
        }
      }
    }
    return HubOperatingHours(days);
  }

  Map<String, dynamic> toJson() => {
    for (final day in hubWeekdays)
      if ((days[day] ?? const []).isNotEmpty)
        day: days[day]!.map((slot) => slot.toJson()).toList(),
  };

  bool get isEmpty => days.values.every((slots) => slots.isEmpty);

  /// Null when valid; otherwise a message for the hub admin.
  String? validate() {
    if (isEmpty) return 'Add at least one opening time.';
    for (final day in hubWeekdays) {
      final slots = [...days[day]!]..sort((a, b) => a.open.compareTo(b.open));
      var previousClose = -1;
      for (final slot in slots) {
        if (!_hhmm.hasMatch(slot.open) ||
            !(slot.close == '24:00' || _hhmm.hasMatch(slot.close))) {
          return '${hubWeekdayLabels[day]}: use HH:MM times.';
        }
        if (slot.closeMinute <= slot.openMinute) {
          return '${hubWeekdayLabels[day]}: closing time must be after opening time.';
        }
        if (slot.openMinute < previousClose) {
          return '${hubWeekdayLabels[day]}: time slots overlap.';
        }
        previousClose = slot.closeMinute;
      }
    }
    return null;
  }

  String dayText(String day) {
    final slots = days[day] ?? const <HubTimeSlot>[];
    return slots.isEmpty
        ? 'Closed'
        : slots.map((slot) => slot.label).join(', ');
  }

  String get todayText => dayText(hubTodayKey());

  /// Opening times on a date, e.g. "9:00 AM – 1:00 PM, 2:00 PM – 5:00 PM" or "Closed".
  String textOn(DateTime day) => dayText(hubDayKey(day));

  /// Last closing time on a date ("17:00"), or null when closed that day.
  String? lastCloseOn(DateTime day) {
    final slots = days[hubDayKey(day)] ?? const <HubTimeSlot>[];
    if (slots.isEmpty) return null;
    return (slots.toList()..sort((a, b) => a.closeMinute.compareTo(b.closeMinute))).last.close;
  }

  /// Whether the hub is open right now (Malaysia time). Display only.
  bool get isOpenNow {
    final now = hubMalaysiaNow();
    final minute = now.hour * 60 + now.minute;
    return (days[hubWeekdays[now.weekday - 1]] ?? const <HubTimeSlot>[]).any(
      (slot) => slot.openMinute <= minute && minute < slot.closeMinute,
    );
  }
}

// Hub admin.

/// One hub managed by the signed-in admin (get_my_hubs).
class HubSummary {
  final String id;
  final String name;
  final String address;
  final double capacityKg;
  final bool active;
  final Map<String, dynamic> raw;

  HubSummary.fromRow(this.raw)
    : id = raw['hub_id'].toString(),
      name = raw['hub_name']?.toString() ?? 'Community hub',
      address = raw['address_text']?.toString() ?? '',
      capacityKg = hubDouble(raw['capacity_kg']),
      active = raw['active_flag'] != false;
}

/// The signed-in hub admin's verification (get_my_hub_admin_status), stored on
/// hub_admin_profiles. The system sets it when every registration check passes.
class HubAdminStatus {
  final bool verified;
  final DateTime? verifiedAt;
  final String? contactPhone;
  final String? hubAddress;

  HubAdminStatus.fromJson(Map<String, dynamic> json)
    : verified = json['verified'] == true,
      verifiedAt = hubDate(json['verified_at']),
      contactPhone = hubText(json['contact_phone']),
      hubAddress = hubText(json['hub_address']);
}

/// Counters for the hub dashboard (get_hub_dashboard).
class HubDashboard {
  final double capacityKg;
  final double committedKg;
  final double availableKg;
  final int awaitingDropOffs;
  final int storedDonations;
  final int publishedBatches;
  final int upcomingCollections;

  HubDashboard.fromJson(Map<String, dynamic> json)
    : capacityKg = hubDouble(json['capacity_kg']),
      committedKg = hubDouble(json['committed_capacity_kg']),
      availableKg = hubDouble(json['available_capacity_kg']),
      awaitingDropOffs = hubInt(json['awaiting_dropoff_count']),
      storedDonations = hubInt(json['stored_donation_count']),
      publishedBatches = hubInt(json['published_batch_count']),
      upcomingCollections = hubInt(json['upcoming_collection_count']);

  double get usedRatio =>
      capacityKg <= 0 ? 0 : (committedKg / capacityKg).clamp(0.0, 1.0);
}

/// Accepted categories and opening hours (get_my_hub_service_rules).
class HubServiceRules {
  final HubOperatingHours hours;
  final List<HubCategoryChoice> categories;
  final bool ready;

  HubServiceRules.fromJson(Map<String, dynamic> json)
    : hours = HubOperatingHours.fromJson(json['operating_hours']),
      categories = (json['categories'] as List? ?? const [])
          .whereType<Map>()
          .map((c) => HubCategoryChoice.fromJson(Map<String, dynamic>.from(c)))
          .toList(),
      ready = json['ready'] == true;

  List<String> get acceptedNames =>
      categories.where((c) => c.accepted).map((c) => c.name).toList();
}

/// Storage the hub has (community_hubs.has_* columns). The AI prefers hubs that have
/// what the donor's items need, e.g. food-safe storage for food.
class HubFacilities {
  bool foodSafeStorage;
  bool fragileShelving;
  bool lockableStoreroom;
  bool vehicleAccess;

  HubFacilities({
    this.foodSafeStorage = false,
    this.fragileShelving = false,
    this.lockableStoreroom = false,
    this.vehicleAccess = false,
  });

  HubFacilities.fromJson(Object? value)
    : foodSafeStorage = value is Map && value['has_food_safe_storage'] == true,
      fragileShelving = value is Map && value['has_fragile_shelving'] == true,
      lockableStoreroom = value is Map && value['has_lockable_storeroom'] == true,
      vehicleAccess = value is Map && value['has_vehicle_access'] == true;

  bool has(String need) => switch (need) {
    'food_safe_storage' => foodSafeStorage,
    'fragile_shelving' => fragileShelving,
    'lockable_storeroom' => lockableStoreroom,
    'vehicle_access' => vehicleAccess,
    _ => false,
  };

  void set(String need, bool value) {
    switch (need) {
      case 'food_safe_storage':
        foodSafeStorage = value;
      case 'fragile_shelving':
        fragileShelving = value;
      case 'lockable_storeroom':
        lockableStoreroom = value;
      case 'vehicle_access':
        vehicleAccess = value;
    }
  }

  Map<String, bool> toJson() => {
    'has_food_safe_storage': foodSafeStorage,
    'has_fragile_shelving': fragileShelving,
    'has_lockable_storeroom': lockableStoreroom,
    'has_vehicle_access': vehicleAccess,
  };
}

/// The four storage needs a category can tick, with the hub facility that meets each.
const hubNeedKeys = [
  'food_safe_storage',
  'fragile_shelving',
  'lockable_storeroom',
  'vehicle_access',
];
const hubNeedLabels = {
  'food_safe_storage': 'Food-safe storage',
  'fragile_shelving': 'Shelves for fragile items',
  'lockable_storeroom': 'Lockable storeroom',
  'vehicle_access': 'Vehicle access',
};

/// An active donation category and the storage it needs (donation_categories).
class DonationCategoryInfo {
  final String id;
  final String name;
  final Set<String> needs;

  DonationCategoryInfo.fromJson(Map<String, dynamic> json)
    : id = json['category_id'].toString(),
      name = json['category_name']?.toString() ?? '',
      needs = {
        for (final key in hubNeedKeys)
          if (json['needs_$key'] == true) key,
      };

  /// "Needs food-safe storage" or null when it needs nothing special.
  String? get needsText => needs.isEmpty
      ? null
      : 'Needs ${needs.map((n) => hubNeedLabels[n]!.toLowerCase()).join(', ')}';
}

class HubCategoryChoice {
  final String id;
  final String name;
  final bool accepted;
  HubCategoryChoice.fromJson(Map<String, dynamic> json)
    : id = json['category_id'].toString(),
      name = json['category_name']?.toString() ?? '',
      accepted = json['accepted'] == true;
}

/// Drop-off status words used by get_my_hub_dropoffs / get_my_hub_dropoff.
enum HubDropOffStatus { awaiting, received, expired, cancelled, other }

HubDropOffStatus hubDropOffStatus(Object? value) => switch (value) {
  'AWAITING' => HubDropOffStatus.awaiting,
  'RECEIVED' => HubDropOffStatus.received,
  'EXPIRED' => HubDropOffStatus.expired,
  'CANCELLED' => HubDropOffStatus.cancelled,
  _ => HubDropOffStatus.other,
};

/// One booked drop-off at the hub (get_my_hub_dropoffs).
class HubDropOff {
  final String reservationId;
  final String referenceCode;
  final String donationId;
  final String title;
  final String? donorName;
  final double reservedKg;
  final int itemCount;
  final String categories;
  final String? photoPath;
  final DateTime? reservedAt;
  final DateTime? expiresAt;
  final HubDropOffStatus status;
  final int? minutesLeft;
  final DateTime? receivedAt;
  final double? receivedKg;

  /// The day the donor will come (any time the hub is open that day).
  DateTime? get dropOffDay => hubDropOffDayOf(expiresAt);

  HubDropOff.fromRow(Map<String, dynamic> row)
    : reservationId = row['reservation_id'].toString(),
      referenceCode = row['reference_code']?.toString() ?? '',
      donationId = row['donation_id'].toString(),
      title = row['title']?.toString() ?? 'Donation',
      donorName = hubText(row['donor_name']),
      reservedKg = hubDouble(row['reserved_weight_kg']),
      itemCount = hubInt(row['item_count']),
      categories = row['category_names']?.toString() ?? '',
      photoPath = hubText(row['primary_image_path']),
      reservedAt = hubDate(row['reserved_at']),
      expiresAt = hubDate(row['expires_at']),
      status = hubDropOffStatus(row['status']),
      minutesLeft = row['minutes_left'] == null
          ? null
          : hubInt(row['minutes_left']),
      receivedAt = hubDate(row['received_at']),
      receivedKg = row['received_weight_kg'] == null
          ? null
          : hubDouble(row['received_weight_kg']);

  /// The latest booking inside get_my_hub_donation_detail (for the receive sheet).
  HubDropOff.fromDonationDetail(Map<String, dynamic> detail)
    : this.fromRow({
        ...Map<String, dynamic>.from(detail['reservation'] as Map? ?? const {}),
        'donation_id': detail['donation_id'],
        'title': detail['title'],
        'donor_name': detail['donor_name'],
        'item_count': (detail['items'] as List? ?? const []).length,
        'primary_image_path':
            (detail['image_paths'] as List? ?? const []).isEmpty
            ? null
            : (detail['image_paths'] as List).first,
      });

  bool get awaiting => status == HubDropOffStatus.awaiting;
}

/// One donation in hub custody (get_my_hub_inventory_v2).
class HubStoredDonation {
  final String donationId;
  final String title;
  final String inventoryStatus;
  final double weightKg;
  final DateTime? receivedAt;
  final int waitingMinutes;
  final String categoryName;
  final bool singleCategory;
  final String? batchId;
  final String? photoPath;

  HubStoredDonation.fromRow(Map<String, dynamic> row)
    : donationId = row['donation_id'].toString(),
      title = row['title']?.toString() ?? 'Donation',
      inventoryStatus = row['inventory_status']?.toString() ?? '',
      weightKg = hubDouble(row['received_weight_kg']),
      receivedAt = hubDate(row['received_at']),
      waitingMinutes = hubInt(row['waiting_minutes']),
      categoryName = row['category_name']?.toString() ?? '—',
      singleCategory = row['single_category'] == true,
      batchId = hubText(row['batch_id']),
      photoPath = hubText(row['primary_image_path']);

  bool get stored => inventoryStatus == 'STORED';
}

/// Result of check_hub_batch for the ticked donations.
class HubBatchCheck {
  final bool ok;
  final int donationCount;
  final double totalKg;
  final String? categoryName;
  final int minDonations;
  final int maxDonations;
  final double maxKg;
  final List<String> problems;
  final List<String> warnings;

  HubBatchCheck.fromJson(Map<String, dynamic> json)
    : ok = json['ok'] == true,
      donationCount = hubInt(json['donation_count']),
      totalKg = hubDouble(json['total_weight_kg']),
      categoryName = hubText(json['category_name']),
      minDonations = hubInt(json['min_donations']),
      maxDonations = hubInt(json['max_donations']),
      maxKg = hubDouble(json['max_weight_kg']),
      problems = _messages(json['problems']),
      warnings = _messages(json['warnings']);

  HubBatchCheck.failed(String message)
    : ok = false,
      donationCount = 0,
      totalKg = 0,
      categoryName = null,
      minDonations = 3,
      maxDonations = 5,
      maxKg = 30,
      problems = [message],
      warnings = const [];

  static List<String> _messages(Object? list) => (list as List? ?? const [])
      .whereType<Map>()
      .map((p) => p['message']?.toString() ?? p['code']?.toString() ?? '')
      .where((m) => m.isNotEmpty)
      .toList();
}

/// Pickup progress of a published batch listing.
enum HubListingStage {
  waitingForNgo,
  claimed,
  pickupInProgress,
  collected,
  handoverReview,
  cancelled,
}

HubListingStage hubListingStage(Object? value) => switch (value) {
  'CLAIMED' => HubListingStage.claimed,
  'PICKUP_IN_PROGRESS' => HubListingStage.pickupInProgress,
  'COLLECTED' => HubListingStage.collected,
  'HANDOVER_REVIEW' => HubListingStage.handoverReview,
  'CANCELLED' => HubListingStage.cancelled,
  _ => HubListingStage.waitingForNgo,
};

/// One published batch listing with the NGO pickup progress (get_my_hub_listings).
class HubBatchListing {
  final String batchId;
  final String batchStatus;
  final String categoryName;
  final double weightKg;
  final int donationCount;
  final DateTime? publishedAt;
  final String? coverPath;
  final String? listingStatus;
  final String? claimId;
  final String? claimStatus;
  final DateTime? claimedAt;
  final String? ngoName;
  final String? ngoPhone;
  final DateTime? leaseExpiresAt;
  final String? taskStatus;
  final DateTime? collectedAt;
  final String? caseId;
  final String? caseStatus;
  final int endedClaimCount;
  final HubListingStage stage;

  HubBatchListing.fromRow(Map<String, dynamic> row)
    : batchId = row['batch_id'].toString(),
      batchStatus = row['batch_status']?.toString() ?? '',
      categoryName = row['category_name']?.toString() ?? 'Mixed',
      weightKg = hubDouble(row['batch_weight_kg']),
      donationCount = hubInt(row['batch_donation_count']),
      publishedAt = hubDate(row['published_at']),
      coverPath = hubText(row['cover_path']),
      listingStatus = hubText(row['listing_status']),
      claimId = hubText(row['claim_id']),
      claimStatus = hubText(row['claim_status']),
      claimedAt = hubDate(row['claimed_at']),
      ngoName = hubText(row['ngo_name']),
      ngoPhone = hubText(row['ngo_phone']),
      leaseExpiresAt = hubDate(row['lease_expires_at']),
      taskStatus = hubText(row['task_status']),
      collectedAt = hubDate(row['collected_at']),
      caseId = hubText(row['case_id']),
      caseStatus = hubText(row['case_status']),
      endedClaimCount = hubInt(row['ended_claim_count']),
      stage = hubListingStage(row['progress_stage']);

  bool get isOpen =>
      stage != HubListingStage.collected && stage != HubListingStage.cancelled;
  bool get handoverCaseOpen => caseStatus == 'OPEN' && claimId != null;
}

/// One hub notification (get_my_hub_activity).
class HubActivity {
  final String key;
  final String type;
  final DateTime? occurredAt;
  final String title;
  final String message;
  final String? donationId;
  final String? batchId;
  final bool needsAction;

  HubActivity.fromRow(Map<String, dynamic> row)
    : key = row['event_key'].toString(),
      type = row['event_type']?.toString() ?? '',
      occurredAt = hubDate(row['occurred_at']),
      title = row['title']?.toString() ?? '',
      message = row['message']?.toString() ?? '',
      donationId = hubText(row['donation_id']),
      batchId = hubText(row['batch_id']),
      needsAction = row['needs_action'] == true;
}

// Donor.

/// A hub the donor may (or may not) choose for one donation (get_hub_options).
class HubOption {
  final String hubId;
  final String name;
  final String address;
  final double? roadKm;
  final double availableKg;
  final double capacityKg;
  final HubOperatingHours hours;
  final bool feasible;
  final List<String> reasons;

  /// MODEL (AI), REFERENCE_FALLBACK (AI model unavailable) or NEAREST (API not used).
  final String rankingMode;

  /// AI rank among feasible hubs (1 = recommended); null when not AI-ranked.
  final int? rank;

  /// True for the AI's top 3.
  final bool inTopK;

  /// Why the recommended hub is first.
  final String? explanation;

  /// Whether the hub has the storage the donor's items need, e.g. "No lockable storeroom".
  final String? storageNote;

  /// The drop-off day these checks are for, and the hub's last closing time that day
  /// (the booking holds the space until then).
  final DateTime? dropOffDay;
  final DateTime? closesAt;

  bool get aiRanked =>
      rankingMode == 'MODEL' || rankingMode == 'REFERENCE_FALLBACK';

  HubOption.fromRow(Map<String, dynamic> row, {this.rankingMode = 'NEAREST'})
    : explanation = hubText(row['explanation']),
      storageNote = hubText(row['storage_note']),
      dropOffDay = hubParseDay(row['dropoff_date']),
      closesAt = hubDate(row['closes_at']),
      rank = row['rank'] == null ? null : hubInt(row['rank']),
      inTopK = row['in_top_k'] == true,
      hubId = row['hub_id'].toString(),
      name = row['hub_name']?.toString() ?? 'Community hub',
      address = row['address_text']?.toString() ?? '',
      roadKm = row['road_km'] == null ? null : hubDouble(row['road_km']),
      availableKg = hubDouble(row['available_capacity_kg']),
      capacityKg = hubDouble(row['capacity_kg']),
      hours = HubOperatingHours.fromJson(row['operating_hours']),
      feasible = row['feasible'] == true,
      reasons = (row['reasons'] as List? ?? const [])
          .map((r) => r.toString())
          .toList();
}

/// What the donor should do next for a hub donation (get_my_hub_dropoff.next_step).
enum HubNextStep {
  chooseHub,
  dropOff,
  chooseAgain,
  atHub,
  inBatch,
  done,
  cancelled,
  notHub,
}

HubNextStep hubNextStep(Object? value) => switch (value) {
  'CHOOSE_HUB' => HubNextStep.chooseHub,
  'DROP_OFF' => HubNextStep.dropOff,
  'CHOOSE_AGAIN' => HubNextStep.chooseAgain,
  'AT_HUB' => HubNextStep.atHub,
  'IN_BATCH' => HubNextStep.inBatch,
  'DONE' => HubNextStep.done,
  'CANCELLED' => HubNextStep.cancelled,
  _ => HubNextStep.notHub,
};

/// Donor drop-off pass for one donation (get_my_hub_dropoff).
class HubDropOffPass {
  final String donationId;
  final String title;
  final String donationStatus;
  final double weightKg;
  final bool canChooseHub;
  final HubNextStep nextStep;
  final HubPassReservation? reservation;

  HubDropOffPass.fromJson(Map<String, dynamic> json)
    : donationId = json['donation_id'].toString(),
      title = json['title']?.toString() ?? 'Donation',
      donationStatus = json['donation_status']?.toString() ?? '',
      weightKg = hubDouble(json['total_weight_kg']),
      canChooseHub = json['can_choose_hub'] == true,
      nextStep = hubNextStep(json['next_step']),
      reservation = json['reservation'] is Map
          ? HubPassReservation.fromJson(
              Map<String, dynamic>.from(json['reservation'] as Map),
            )
          : null;
}

class HubPassReservation {
  final String reservationId;
  final String referenceCode;
  final HubDropOffStatus status;
  final double reservedKg;
  final DateTime? reservedAt;
  final DateTime? expiresAt;
  final DateTime? receivedAt;
  final double? receivedKg;
  final String hubName;
  final String hubAddress;
  final double? latitude;
  final double? longitude;
  final HubOperatingHours hours;

  /// The day the donor said they will bring the donation.
  final DateTime? dropOffDay;

  HubPassReservation.fromJson(Map<String, dynamic> json)
    : reservationId = json['reservation_id'].toString(),
      referenceCode = json['reference_code']?.toString() ?? '',
      status = hubDropOffStatus(json['status']),
      reservedKg = hubDouble(json['reserved_weight_kg']),
      reservedAt = hubDate(json['reserved_at']),
      expiresAt = hubDate(json['expires_at']),
      dropOffDay =
          hubParseDay(json['dropoff_date']) ?? hubDropOffDayOf(hubDate(json['expires_at'])),
      receivedAt = hubDate(json['received_at']),
      receivedKg = json['received_weight_kg'] == null
          ? null
          : hubDouble(json['received_weight_kg']),
      hubName =
          (json['hub'] as Map?)?['hub_name']?.toString() ?? 'Community hub',
      hubAddress = (json['hub'] as Map?)?['address_text']?.toString() ?? '',
      latitude = (json['hub'] as Map?)?['latitude'] == null
          ? null
          : hubDouble((json['hub'] as Map)['latitude']),
      longitude = (json['hub'] as Map?)?['longitude'] == null
          ? null
          : hubDouble((json['hub'] as Map)['longitude']),
      hours = HubOperatingHours.fromJson(
        (json['hub'] as Map?)?['operating_hours'],
      );
}

// Service

const hubPhotoBucket = 'geolock-donation-images';

class HubService {
  HubService._();

  /// The client main.dart created from [SupabaseConfig].
  static SupabaseClient get _db {
    if (!SupabaseConfig.isConfigured) {
      throw StateError(
        'Supabase is not configured for "${SupabaseConfig.environment}". '
        'Check supabase_config.dart.',
      );
    }
    return Supabase.instance.client;
  }

  static String? get currentUserId => _db.auth.currentUser?.id;

  // Hub registration (checked by the system)

  static Future<HubAdminStatus> adminStatus() async => HubAdminStatus.fromJson(
    hubObject(await _db.rpc('get_my_hub_admin_status')),
  );

  /// Hub details typed on the sign-up form, kept until the hub is created.
  static Map<String, dynamic>? get signUpHubDraft {
    final draft = _db.auth.currentUser?.userMetadata?['geolock_pending_hub'];
    return draft is Map ? Map<String, dynamic>.from(draft) : null;
  }

  static Future<void> clearSignUpHubDraft() async {
    if (signUpHubDraft == null) return;
    await _db.auth.updateUser(
      UserAttributes(data: {'geolock_pending_hub': null}),
    );
  }

  /// Registers the admin's hub. The database checks one hub per account, a contact
  /// phone not used by another account, 200 m from other hubs and road access, then
  /// creates the hub and marks the admin verified. Returns the new hub id.
  static Future<String> registerHub({
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    required double capacityKg,
    required String contactPhone,
  }) async {
    final result = hubObject(
      await _db.rpc(
        'register_my_hub',
        params: {
          'p_hub_name': name,
          'p_hub_address': address,
          'p_lat': latitude,
          'p_lon': longitude,
          'p_capacity_kg': capacityKg,
          'p_contact_phone': contactPhone,
        },
      ),
    );
    return hubText(result['hub_id']) ??
        (throw const FormatException('The database did not register the hub.'));
  }

  /// Edits the hub (update_my_hub). Location and capacity changes are refused while the
  /// hub holds stock, reservations or open batches. Returns the hub's road node id, which
  /// the database works out again from a new pin.
  static Future<String?> updateHub({
    required String hubId,
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    required double capacityKg,
  }) async {
    final result = hubObject(
      await _db.rpc(
        'update_my_hub',
        params: {
          'p_hub': hubId,
          'p_name': name,
          'p_address': address,
          'p_lat': latitude,
          'p_lon': longitude,
          'p_capacity_kg': capacityKg,
        },
      ),
    );
    return hubText(result['road_node_id']);
  }

  /// For a hub created before verification existed: adds the contact phone and runs
  /// the same checks on the existing hub.
  static Future<void> verifyAdmin(String contactPhone) async {
    await _db.rpc(
      'verify_my_hub_admin',
      params: {'p_contact_phone': contactPhone},
    );
  }

  // Hub admin

  static Future<List<HubSummary>> myHubs() async =>
      hubRows(await _db.rpc('get_my_hubs')).map(HubSummary.fromRow).toList();

  static Future<HubDashboard> dashboard(String hubId) async =>
      HubDashboard.fromJson(
        hubObject(await _db.rpc('get_hub_dashboard', params: {'p_hub': hubId})),
      );

  static Future<HubServiceRules> serviceRules(String hubId) async =>
      HubServiceRules.fromJson(
        hubObject(
          await _db.rpc('get_my_hub_service_rules', params: {'p_hub': hubId}),
        ),
      );

  static Future<void> saveServiceRules(
    String hubId,
    Set<String> categoryIds,
    HubOperatingHours hours,
  ) async {
    await _db.rpc(
      'set_my_hub_service_rules',
      params: {
        'p_hub': hubId,
        'p_category_ids': categoryIds.toList(),
        'p_operating_hours': hours.toJson(),
      },
    );
  }

  static const _categoryColumns =
      'category_id,category_name,needs_food_safe_storage,needs_fragile_shelving,'
      'needs_lockable_storeroom,needs_vehicle_access';

  /// Active categories with the storage each needs. Also works before log-in (hub sign-up).
  static Future<List<DonationCategoryInfo>> categories() async =>
      hubRows(
        await _db
            .from('donation_categories')
            .select(_categoryColumns)
            .eq('active_flag', true)
            .order('category_name'),
      ).map(DonationCategoryInfo.fromJson).toList();

  static const _facilityColumns =
      'has_food_safe_storage,has_fragile_shelving,'
      'has_lockable_storeroom,has_vehicle_access';

  static Future<HubFacilities> facilities(String hubId) async =>
      HubFacilities.fromJson(
        await _db
            .from('community_hubs')
            .select(_facilityColumns)
            .eq('hub_id', hubId)
            .single(),
      );

  /// Only the hub's own admin can change these columns (row policy in the database).
  static Future<void> saveFacilities(String hubId, HubFacilities f) async {
    final saved = await _db
        .from('community_hubs')
        .update(f.toJson())
        .eq('hub_id', hubId)
        .select('hub_id');
    if (saved.isEmpty) throw Exception('HUB_NOT_FOUND_OR_FORBIDDEN');
  }

  static Future<List<HubDropOff>> dropOffs(String hubId) async => hubRows(
    await _db.rpc('get_my_hub_dropoffs', params: {'p_hub': hubId}),
  ).map(HubDropOff.fromRow).toList();

  /// Confirms the donor handed the donation in; the donation becomes AT_HUB.
  static Future<void> confirmReceipt(
    String reservationId,
    double weightKg,
  ) async {
    final receipt = await _db.rpc(
      'confirm_hub_receipt',
      params: {'p_reservation': reservationId, 'p_received_weight': weightKg},
    );
    if (hubText(receipt) == null) {
      throw const FormatException('The database did not confirm the receipt.');
    }
  }

  static Future<List<HubStoredDonation>> inventory(String hubId) async =>
      hubRows(
        await _db.rpc('get_my_hub_inventory_v2', params: {'p_hub': hubId}),
      ).map(HubStoredDonation.fromRow).toList();

  static Future<Map<String, dynamic>> donationDetail(
    String hubId,
    String donationId,
  ) async => hubObject(
    await _db.rpc(
      'get_my_hub_donation_detail',
      params: {'p_hub': hubId, 'p_donation': donationId},
    ),
  );

  static Future<HubBatchCheck> checkBatch(
    String hubId,
    List<String> donationIds,
  ) async => HubBatchCheck.fromJson(
    hubObject(
      await _db.rpc(
        'check_hub_batch',
        params: {'p_hub': hubId, 'p_donation_ids': donationIds},
      ),
    ),
  );

  /// Publishes the ticked donations as one HUB_BATCH listing; returns the batch id.
  static Future<String> publishBatch(
    String hubId,
    List<String> donationIds,
  ) async {
    final batchId = await _db.rpc(
      'publish_whole_donation_batch',
      params: {'p_hub': hubId, 'p_donation_ids': donationIds},
    );
    return hubText(batchId) ??
        (throw const FormatException(
          'The database did not publish the batch.',
        ));
  }

  static Future<List<HubBatchListing>> listings(String hubId) async => hubRows(
    await _db.rpc('get_my_hub_listings', params: {'p_hub': hubId}),
  ).map(HubBatchListing.fromRow).toList();

  static Future<Map<String, dynamic>> batchDetail(
    String hubId,
    String batchId,
  ) async => hubObject(
    await _db.rpc(
      'get_hub_batch_details',
      params: {'p_hub': hubId, 'p_batch': batchId},
    ),
  );

  static Future<List<HubActivity>> activity(
    String hubId, {
    int limit = 60,
  }) async => hubRows(
    await _db.rpc(
      'get_my_hub_activity',
      params: {'p_hub': hubId, 'p_limit': limit},
    ),
  ).map(HubActivity.fromRow).toList();

  /// Hub admin's answer for an open handover case of a claimed batch.
  static Future<void> confirmHandover(
    String claimId, {
    required bool collected,
  }) async {
    await _db.rpc(
      'submit_claim_reconciliation',
      params: {
        'p_claim': claimId,
        'p_handover_confirmed': collected,
        'p_request': const Uuid().v4(),
      },
    );
  }

  /// Uploads a cover photo for a published batch (JPG, PNG or WebP up to 5 MB).
  static Future<void> addBatchPhoto(String batchId, File file) async {
    final userId = currentUserId;
    if (userId == null) throw StateError('Please sign in again.');
    final ext = file.path.split('.').last.toLowerCase();
    final size = await file.length();
    if (!const {'jpg', 'jpeg', 'png', 'webp'}.contains(ext) ||
        size > 5 * 1024 * 1024) {
      throw StateError('Choose a JPG, PNG or WebP image up to 5 MB.');
    }
    final mime = switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    final path = '$userId/batches/$batchId/${const Uuid().v4()}.$ext';
    final storage = _db.storage.from(hubPhotoBucket);
    await storage.upload(
      path,
      file,
      fileOptions: FileOptions(contentType: mime, upsert: false),
    );
    try {
      await _db.rpc(
        'add_hub_batch_image',
        params: {
          'p_batch': batchId,
          'p_storage_path': path,
          'p_content_type': mime,
          'p_size_bytes': size,
        },
      );
    } catch (_) {
      try {
        await storage.remove([path]);
      } catch (_) {}
      rethrow;
    }
  }

  static Future<String> signedPhotoUrl(String path) =>
      _db.storage.from(hubPhotoBucket).createSignedUrl(path, 900);

  // Donor

  static Future<HubDropOffPass> dropOffPass(String donationId) async =>
      HubDropOffPass.fromJson(
        hubObject(
          await _db.rpc(
            'get_my_hub_dropoff',
            params: {'p_donation': donationId},
          ),
        ),
      );

  /// Hubs within 20 km for the drop-off [day] (Malaysia date, default today): feasible
  /// first, then the others with reasons. Uses the AI ranking API when set; falls back to
  /// get_hub_options if it fails.
  static Future<List<HubOption>> hubOptions(
    String donationId, {
    DateTime? day,
  }) async {
    final date = hubIsoDate(day ?? hubToday());
    final base = await _rankingApi();
    if (base != null) {
      try {
        return await _aiRankedHubOptions(base, donationId, date);
      } catch (error) {
        debugPrint('[HubRanking] AI ranking failed, using nearest hubs: $error');
        _workingApi = null; // look for it again next time
      }
    }
    return hubRows(
      await _db.rpc(
        'get_hub_options',
        params: {'p_donation': donationId, 'p_dropoff_date': date},
      ),
    ).map((row) => HubOption.fromRow(row)).toList();
  }

  static String? _workingApi;
  static DateTime? _lastMiss;

  /// First API address that answers /health. A miss is remembered for a minute so
  /// the hub list does not wait every time the API is off.
  static Future<String?> _rankingApi() async {
    if (_workingApi != null) return _workingApi;
    final lastMiss = _lastMiss;
    if (lastMiss != null && DateTime.now().difference(lastMiss).inSeconds < 60) {
      return null;
    }
    final candidates = [
      if (hubRankingApiUrl.isNotEmpty) hubRankingApiUrl,
      if (hostedRankingApiUrl.isNotEmpty) hostedRankingApiUrl,
      ..._localRankingApis,
    ].map((url) => url.replaceFirst(RegExp(r'/+$'), ''));
    for (final url in candidates) {
      // A sleeping Render free server needs 30-60 s to wake up; this PC answers at once.
      final wait = url.startsWith('https') ? 60 : 2;
      try {
        final response = await http
            .get(Uri.parse('$url/health'))
            .timeout(Duration(seconds: wait));
        if (response.statusCode == 200) return _workingApi = url;
        debugPrint('[HubRanking] $url/health returned ${response.statusCode}');
      } catch (error) {
        debugPrint('[HubRanking] $url/health failed: $error'); // try the next one
      }
    }
    _lastMiss = DateTime.now();
    return null;
  }

  static Future<List<HubOption>> _aiRankedHubOptions(
    String base,
    String donationId,
    String date,
  ) async {
    final token = _db.auth.currentSession?.accessToken;
    if (token == null) throw StateError('Not signed in.');
    final response = await http
        .post(
          Uri.parse('$base/v1/hub-ranking'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'donation_id': donationId, 'dropoff_date': date}),
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode != 200) {
      throw HttpException(
        'Hub ranking service returned ${response.statusCode}: ${response.body}',
      );
    }
    debugPrint('[HubRanking] AI ranking OK from $base');
    final body = hubObject(jsonDecode(response.body));
    final mode = body['ranking_mode']?.toString() ?? 'MODEL';
    return hubRows(
      body['hubs'],
    ).map((row) => HubOption.fromRow(row, rankingMode: mode)).toList();
  }

  /// Books [hubId] for the drop-off [day]: the space is held until the hub's last
  /// closing time that day. The donation becomes HUB_ASSIGNED.
  static Future<void> reserveHub(
    String donationId,
    String hubId, {
    required DateTime day,
  }) async {
    final reservation = await _db.rpc(
      'reserve_hub_capacity',
      params: {
        'p_donation': donationId,
        'p_hub': hubId,
        'p_dropoff_date': hubIsoDate(day),
      },
    );
    if (hubText(reservation) == null) {
      throw const FormatException(
        'The database did not confirm the reservation.',
      );
    }
  }
}
