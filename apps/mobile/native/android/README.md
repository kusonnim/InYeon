# Planned Android notification boundary

The share receiver and its Kotlin persistence interface live in the
[Android runner](../../android/app/src/main/kotlin/com/itda/itda_mobile/).
`NotificationContract` remains a design interface for the later notification milestone.

Use a stable platform notification ID per content. Track active/dismissed,
generation, revision and local dismissal tombstones durably. Only explicit
restoration creates a new generation. Ignore delayed dismissals for older
generations. Suppress automatic resurrection after process death, analysis,
push, sync and permission changes. Body tap opens `/contents/{id}`. The sole
quick action is Edit (수정하기).
