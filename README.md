# probe204

Минимальный HTTP 204 probe-сервер для проверки доступности маршрута и замера задержки через реальные TCP/HTTP-соединения.

Сервис поднимает простой HTTP endpoint:

```text
GET /generate_204 -> HTTP 204 No Content
```

Это удобно для проверки маршрутов через WireGuard, VLESS/Xray, SOCKS5, reverse proxy или другие сетевые цепочки, где обычный ICMP ping не отражает реальную доступность канала.

## Что устанавливается

Инсталлятор создаёт:

```text
/opt/probe/probe.py
/etc/systemd/system/probe204.service
```

После установки сервис запускается через systemd и автоматически стартует после перезагрузки.

## Быстрая установка

```bash
bash <(curl -Ls https://raw.githubusercontent.com/USERNAME/probe204/main/install.sh)
```

Замените `USERNAME` на имя вашего GitHub-аккаунта.

## Порт по умолчанию

По умолчанию probe-сервер слушает порт:

```text
18080/tcp
```

Во время установки можно указать другой порт.

## Проверка работы

Локально на сервере:

```bash
curl -i http://127.0.0.1:18080/generate_204
```

Ожидаемый ответ:

```text
HTTP/1.0 204 No Content
```

С удалённой машины:

```bash
curl -i http://SERVER_IP:18080/generate_204
```

## Пример замера задержки

```bash
curl -o /dev/null -s -w "%{time_total}\n" http://SERVER_IP:18080/generate_204
```

Через SOCKS5:

```bash
curl --socks5-hostname 127.0.0.1:10101 \
  -o /dev/null -s \
  -w "%{time_total}\n" \
  http://SERVER_IP:18080/generate_204
```

## Управление сервисом

Статус:

```bash
sudo systemctl status probe204 --no-pager
```

Перезапуск:

```bash
sudo systemctl restart probe204
```

Остановка:

```bash
sudo systemctl stop probe204
```

Отключение автозапуска:

```bash
sudo systemctl disable probe204
```

## Важно про firewall

Инсталлятор может открыть порт через `ufw`, если `ufw` установлен и активен.

Но порт также может быть закрыт на уровне:

- панели VPS/хостера;
- внешнего firewall;
- security group;
- cloud firewall;
- роутера/NAT.

После установки обязательно проверьте, что выбранный TCP-порт открыт снаружи.

## Совместимость

Ориентировано на Ubuntu/Debian-серверы с systemd и Python 3.

## Удаление

```bash
sudo systemctl disable --now probe204
sudo rm -f /etc/systemd/system/probe204.service
sudo rm -rf /opt/probe
sudo systemctl daemon-reload
```
