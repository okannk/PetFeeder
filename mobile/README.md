# PetFeeder Mobile (Flutter)

Backend'e (`../backend`) REST ile bağlanan basit bir mobil kontrol
uygulaması: cihaz listesi, anında besleme, zamanlama, geçmiş.

`lib/` ve `pubspec.yaml` elle yazıldı; `android/` ve `ios/` klasörleri
**yok** — bunları gerçek Flutter toolchain'iyle oluşturman gerekiyor
(elle yazmak native proje dosyalarında ince hatalara yol açabilir).

## 1) Flutter SDK kur

[docs.flutter.dev/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows)
adımlarını izle. Android'de test edeceksen Android Studio + bir Android SDK
kurulu olmalı (fiziksel telefon + USB hata ayıklama da yeterli, emülatöre
gerek yok). `flutter doctor` komutunun kritik satırları yeşil göstermesi
yeterli.

## 2) Native klasörleri oluştur

```bash
cd mobile
flutter create --org com.petfeeder .
```

Bu komut mevcut `lib/` ve `pubspec.yaml`'a dokunmadan `android/`, `ios/` vb.
klasörleri oluşturur (isim çakışması olursa üzerine yazmak isteyip
istemediğini soracak — `lib/` ve `pubspec.yaml` için **hayır** de, sadece
platform klasörleri için gerekiyorsa evet de).

## 3) ⚠️ Yerel ağda http:// izni ver (önemli, atlarsan uygulama hiç bağlanamaz)

Backend `http://` (TLS'siz) çalışıyor. Hem Android hem iOS varsayılan olarak
şifresiz ağ isteklerini engeller — bu adımı atlarsan her istek sessizce
başarısız olur.

**Android** — `android/app/src/main/AndroidManifest.xml` içinde `<application`
etiketine ekle:

```xml
<application
    android:usesCleartextTraffic="true"
    ...>
```

**iOS** — `ios/Runner/Info.plist` içine ekle:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

## 4) Bağımlılıkları kur ve çalıştır

```bash
cd mobile
flutter pub get
flutter run
```

Telefonu USB ile bağlayıp hata ayıklamayı aç, `flutter run` cihazı otomatik
bulur. Uygulama ilk açılışta Ayarlar ekranını gösterir — backend'in çalıştığı
bilgisayarın yerel IP'sini gir (örn. `http://192.168.1.10:3001`). Telefon ile
bilgisayarın **aynı WiFi ağında** olması gerekiyor.

## Notlar

- Cihaz ekleme ekranı `POST /api/devices` çağırır ve token'ı sadece bir kez
  gösterir — cihazın WiFi kurulum portaline (`PetFeeder-Setup`) o token'ı
  gireceksin.
- Liste ekranı 5 saniyede bir otomatik yenilenir (web panelindeki gibi).
- Bu ortamda Flutter SDK kurulu olmadığı için `flutter pub get` /
  `flutter analyze` / `flutter run` çalıştırılıp doğrulanamadı — kodu elle
  gözden geçirdim ama ilk çalıştırmada küçük bir hata çıkarsa (paket sürüm
  uyuşmazlığı vb.) beklenebilir, birlikte düzeltiriz.
