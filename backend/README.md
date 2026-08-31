# PetFeeder Backend

ESP8266 cihazı ile web panelini birbirine bağlayan basit Node.js sunucusu.
Veriler `backend/data/db.json` dosyasında tutulur (harici veritabanı gerekmez).

## Kurulum

```bash
cd backend
npm install
npm start
```

Sunucu varsayılan olarak `http://localhost:3001` üzerinde çalışır ve `web/`
klasöründeki paneli de aynı adresten sunar (`http://localhost:3001/`).

## Cihaz ekleme

```bash
curl -X POST http://localhost:3001/api/devices -H "Content-Type: application/json" -d "{\"name\":\"Mutfak\"}"
```

Yanıttaki `token` değerini cihazın kurulum portalindeki "Cihaz Token" alanına
gir (veya `config.h`'daki `DEVICE_TOKEN_DEFAULT`'a yaz, sonra portalde
değiştirmeden devam et). Token yalnızca oluşturma anında dönülür, tekrar
listelenmez.

## API özeti

| Yöntem | Yol                              | Açıklama                          |
|--------|-----------------------------------|------------------------------------|
| POST   | `/api/devices`                    | Yeni cihaz + token oluştur         |
| GET    | `/api/devices`                    | Cihazları listele (online durumu)  |
| GET    | `/api/devices/:id`                | Cihaz detayı                       |
| POST   | `/api/devices/:id/feed`           | Anında besleme (`{portions}`)      |
| POST   | `/api/devices/:id/schedule`       | Zamanlama güncelle                 |
| GET    | `/api/devices/:id/history`        | Besleme geçmişi                    |
| WS     | `/ws/device?token=...`            | Cihaz bağlantısı (firmware kullanır)|

## Notlar

- Bu bir yerel ağ/ev projesi için minimal bir iskelettir; internete açık bir
  sunucuda barındıracaksan `wss://` (TLS) ve kimlik doğrulamalı bir web paneli
  eklemeni öneririm.
- `data/` klasörü `.gitignore`'da — gerçek cihaz token'ları repoya girmez.
