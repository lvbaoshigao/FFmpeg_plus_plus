"""
FFmpeg++ Lanzou Cloud downloader helper.
Usage: python lanzou_helper.py <share_url> <save_path>
Outputs JSON lines: {"log":...} {"progress":...} {"ok":true/false,...}
"""
import re, sys, json, os, requests

ACW_ORDER = [0xf,0x23,0x1d,0x18,0x21,0x10,0x1,0x26,0xa,0x9,0x13,0x1f,0x28,0x1b,0x16,0x17,0x19,0xd,0x6,0xb,0x27,0x12,0x14,0x8,0xe,0x15,0x20,0x1a,0x2,0x1e,0x7,0x4,0x11,0x5,0x3,0x1c,0x22,0x25,0xc,0x24]
ACW_KEY = "3000176000856006061501533003690027800375"
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.159 Safari/537.36'

def solve_acw(arg1):
    q = [''] * len(ACW_ORDER)
    for i, ch in enumerate(arg1):
        for j in range(len(ACW_ORDER)):
            if ACW_ORDER[j] == i + 1: q[j] = ch
    u = ''.join(q); v = ''
    for i in range(0, min(len(u), len(ACW_KEY)), 2):
        a = int(u[i:i+2], 16) ^ int(ACW_KEY[i:i+2], 16)
        h = format(a, 'x'); v += ('0'+h if len(h)==1 else h)
    return v

def log(msg): print(json.dumps({"log": msg}), flush=True)

def resolve_and_download(share_url, save_path):
    s = requests.Session()
    s.headers['User-Agent'] = UA
    base = re.match(r'(https?://[^/]+)', share_url).group(1)

    log("解析分享页面...")
    r1 = s.get(share_url, timeout=15)
    m = re.search(r"var arg1='([A-F0-9]+)'", r1.text)
    if m:
        s.cookies.set('acw_sc__v2', solve_acw(m.group(1)))
        r1 = s.get(share_url, timeout=15)

    log("获取文件信息...")
    iframes = re.findall(r'iframe[^>]+src="(/fn\?[^"]+)"', r1.text)
    if not iframes:
        return False, "未找到下载iframe"

    log("解析下载参数...")
    r3 = s.get(base + iframes[0], headers={'Referer': share_url}, timeout=15)
    signs = re.findall(r"var [a-z_]+ = '([a-zA-Z0-9_/+=]+)'", r3.text)
    posts = re.findall(r"url\s*:\s*'(/ajaxm\.php[^']*)'", r3.text)
    if not posts or len(signs) < 2:
        return False, "无法解析下载签名"

    log("获取下载地址...")
    r4 = s.post(base + posts[0],
        data={'action': 'downprocess', 'sign': signs[1], 'p': signs[2] if len(signs) > 2 else '', 'kd': 1},
        headers={'Referer': base + iframes[0], 'X-Requested-With': 'XMLHttpRequest'}, timeout=15)
    j4 = r4.json()
    if j4.get('zt') != 1:
        return False, f"获取下载页面失败"

    file_url = j4['dom'] + '/file/' + j4['url']
    log(f"开始下载...")

    r5 = requests.get(file_url, headers={
        'accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'cookie': 'down_ip=1',
        'user-agent': UA,
    }, timeout=30, stream=True, allow_redirects=True)

    total = int(r5.headers.get('Content-Length', 0))
    if total > 0:
        log(f"文件大小: {total/1024/1024:.1f} MB")
    else:
        ct = r5.headers.get('Content-Type', '')
        if 'html' in ct:
            return False, "下载失败：服务器返回HTML而非文件"

    os.makedirs(os.path.dirname(os.path.abspath(save_path)), exist_ok=True)
    received = 0
    with open(save_path, 'wb') as f:
        for chunk in r5.iter_content(chunk_size=65536):
            f.write(chunk)
            received += len(chunk)
            if total > 0:
                pct = min(received * 100 // total, 100)
                print(json.dumps({"progress": pct, "received": received, "total": total}), flush=True)

    if received < 1000000:
        os.remove(save_path)
        return False, f"下载文件过小({received}字节)，可能不是真实文件"

    log(f"下载完成: {received/1024/1024:.1f} MB → {save_path}")
    return True, save_path

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "error": "Usage: lanzou_helper.py <url> <save_path>"}))
        sys.exit(1)
    try:
        ok, result = resolve_and_download(sys.argv[1], sys.argv[2])
        print(json.dumps({"ok": ok, "path": result} if ok else {"ok": False, "error": result}))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)
