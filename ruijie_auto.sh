#!/bin/sh
# 你的校园网账号密码
USERNAME="2021090020"
PASSWORD="111514"
# 检测间隔(秒)
CHECK_TIME=30

# 循环检测网络
while true; do
    DATE=$(date "+%Y-%m-%d %H:%M:%S")
    # 【原版检测方式】你另一个路由器正常的逻辑
    captiveReturnCode=$(curl -s -I -m 10 -o /dev/null -s -w %{http_code} http://www.google.cn/generate_204)

    if [ "${captiveReturnCode}" = "204" ]; then
        echo "[$DATE] ✅ 网络正常，无需认证"
    else
        echo "[$DATE] ❌ 网络断开，开始自动登录..."

        # =============== 以下完全是你【正常可用的原版脚本】 ===============
        loginPageURL=$(curl -s "http://www.google.cn/generate_204" | awk -F \' '{print $2}')
        loginURL=$(echo ${loginPageURL} | awk -F \? '{print $1}')
        loginURL="${loginURL/index.jsp/InterFace.do?method=login}"
        queryString=$(echo ${loginPageURL} | awk -F \? '{print $2}')
        queryString="${queryString//&/%2526}"
        queryString="${queryString//=/%253D}"
        service=""

        if [ -n "${loginURL}" ]; then
            authResult=$(curl -s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.91 Safari/537.36" -e "${loginPageURL}" -b "EPORTAL_COOKIE_USERNAME=; EPORTAL_COOKIE_PASSWORD=;" -d "userId=${USERNAME}&password=${PASSWORD}&service=${service}&queryString=${queryString}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false" -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" "${loginURL}")
            echo "[$DATE] 🔑 认证结果：$authResult"
        fi
        # ==============================================================
    fi

    sleep $CHECK_TIME
done
