// ==UserScript==
// @name         GitHub 智能加速下载插件（带实时面板）
// @namespace    https://github.com/Star7-Files-Hub/
// @version      1.1
// @description  自动测速多个GitHub加速域名，实时展示最快域名，点击下载时使用最快地址
// @author       7Star
// @match        *://github.com/*
// @grant        GM_xmlhttpRequest
// @connect      *
// @run-at       document-end
// @supportURL   https://github.com/Star7-Files-Hub/Files/issues
// ==/UserScript==

(function() {
    'use strict';

    // ===================== 配置区（可自行修改）=====================
    // 加速域名列表 - 你可以添加/删除/修改这里的加速地址
    const ACCELERATE_DOMAINS = [
        'https://dl.motrix.cloud/',
        'https://github-proxy.lixxing.top/',
        'https://ghproxy.net/',
        'https://gh.con.sh/'
    ];
    // 测速用的测试文件（GitHub公开小文件，保证测速准确性）
    const TEST_FILE_URL = 'https://github.com/oopsunix/ghproxy/archive/refs/tags/v1.0.0.zip';
    // 超时时间（毫秒）
    const TIMEOUT = 5000;
    // 面板是否默认固定在右侧（true=固定，false=可拖动）
    const PANEL_FIXED = false;
    // ==============================================================

    // 存储测速结果：{ domain: 耗时(ms), ... }
    let speedTestResults = {};
    // 最快的加速域名
    let fastestDomain = ACCELERATE_DOMAINS[0];
    // 悬浮面板DOM元素
    let speedPanel = null;

    /**
     * 创建并初始化测速面板
     */
    function createSpeedPanel() {
        // 创建面板容器
        speedPanel = document.createElement('div');
        speedPanel.id = 'github-accelerate-panel';
        speedPanel.style.cssText = `
            position: ${PANEL_FIXED ? 'fixed' : 'absolute'};
            top: 80px;
            right: 20px;
            width: 280px;
            background: #ffffff;
            border: 1px solid #e1e4e8;
            border-radius: 8px;
            padding: 12px;
            font-size: 13px;
            z-index: 99999;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            ${!PANEL_FIXED ? 'cursor: move;' : ''}
        `;

        // 面板标题
        const panelTitle = document.createElement('div');
        panelTitle.style.cssText = `
            font-weight: 600;
            color: #24292f;
            margin-bottom: 8px;
            padding-bottom: 8px;
            border-bottom: 1px solid #f0f0f0;
            display: flex;
            justify-content: space-between;
            align-items: center;
        `;
        panelTitle.innerHTML = `
            <span>GitHub 加速测速</span>
            <button id="panel-close" style="border: none; background: transparent; cursor: pointer; color: #666; font-size: 16px; padding: 0 4px;">×</button>
        `;

        // 最快域名展示区
        const fastestArea = document.createElement('div');
        fastestArea.id = 'fastest-domain-area';
        fastestArea.style.cssText = `
            background: #f6f8fa;
            border-radius: 6px;
            padding: 8px;
            margin-bottom: 10px;
        `;
        fastestArea.innerHTML = `
            <div style="color: #57606a; font-size: 12px; margin-bottom: 4px;">当前最快</div>
            <div id="fastest-domain" style="color: #2ea44f; font-weight: 600; word-break: break-all;">测速中...</div>
        `;

        // 测速结果列表
        const resultsList = document.createElement('div');
        resultsList.id = 'speed-results-list';
        resultsList.style.cssText = `
            max-height: 200px;
            overflow-y: auto;
        `;

        // 初始化列表内容
        let listHtml = '';
        ACCELERATE_DOMAINS.forEach(domain => {
            listHtml += `
                <div id="domain-${domain.replace(/[^a-zA-Z0-9]/g, '')}" style="padding: 4px 0; border-bottom: 1px solid #f9f9f9;">
                    <div style="color: #24292f; font-size: 12px; word-break: break-all;">${domain}</div>
                    <div style="color: #666; font-size: 11px; margin-top: 2px;">状态：测速中...</div>
                </div>
            `;
        });
        resultsList.innerHTML = listHtml;

        // 组装面板
        speedPanel.appendChild(panelTitle);
        speedPanel.appendChild(fastestArea);
        speedPanel.appendChild(resultsList);
        document.body.appendChild(speedPanel);

        // 关闭按钮事件
        document.getElementById('panel-close').addEventListener('click', () => {
            speedPanel.remove();
        });

        // 可拖动功能（如果未固定）
        if (!PANEL_FIXED) {
            makePanelDraggable(speedPanel);
        }
    }

    /**
     * 使面板可拖动
     * @param {HTMLElement} element 面板元素
     */
    function makePanelDraggable(element) {
        let pos1 = 0, pos2 = 0, pos3 = 0, pos4 = 0;
        element.onmousedown = dragMouseDown;

        function dragMouseDown(e) {
            e = e || window.event;
            e.preventDefault();
            // 获取鼠标初始位置
            pos3 = e.clientX;
            pos4 = e.clientY;
            document.onmouseup = closeDragElement;
            // 当鼠标移动时触发拖动
            document.onmousemove = elementDrag;
        }

        function elementDrag(e) {
            e = e || window.event;
            e.preventDefault();
            // 计算新位置
            pos1 = pos3 - e.clientX;
            pos2 = pos4 - e.clientY;
            pos3 = e.clientX;
            pos4 = e.clientY;
            // 设置元素新位置
            element.style.top = (element.offsetTop - pos2) + "px";
            element.style.left = (element.offsetLeft - pos1) + "px";
        }

        function closeDragElement() {
            // 停止拖动
            document.onmouseup = null;
            document.onmousemove = null;
        }
    }

    /**
     * 更新面板中的测速状态
     * @param {string} domain 加速域名
     * @param {number} costTime 耗时（ms），Infinity表示失败/超时
     */
    function updatePanelStatus(domain, costTime) {
        if (!speedPanel) return;

        // 生成唯一ID（替换特殊字符）
        const domainId = `domain-${domain.replace(/[^a-zA-Z0-9]/g, '')}`;
        const domainElement = document.getElementById(domainId);

        if (domainElement) {
            let statusText, statusColor;
            if (costTime === Infinity) {
                statusText = '状态：超时/失败 ❌';
                statusColor = '#d73a4a';
            } else {
                statusText = `状态：${costTime}ms ✔️`;
                statusColor = '#2ea44f';
            }

            domainElement.innerHTML = `
                <div style="color: #24292f; font-size: 12px; word-break: break-all;">${domain}</div>
                <div style="color: ${statusColor}; font-size: 11px; margin-top: 2px;">${statusText}</div>
            `;
        }
    }

    /**
     * 更新最快域名展示
     */
    function updateFastestDomain() {
        if (!speedPanel) return;

        const fastestElement = document.getElementById('fastest-domain');
        if (fastestElement) {
            fastestElement.textContent = fastestDomain;
        }
    }

    /**
     * 测速单个加速域名
     * @param {string} domain 加速域名
     * @returns {Promise<number>} 耗时（毫秒），超时返回Infinity
     */
    function testSingleDomainSpeed(domain) {
        return new Promise((resolve) => {
            const startTime = Date.now();
            const testUrl = domain + TEST_FILE_URL;

            GM_xmlhttpRequest({
                method: 'HEAD', // 只请求头，不下载文件，测速更高效
                url: testUrl,
                timeout: TIMEOUT,
                onload: function() {
                    const costTime = Date.now() - startTime;
                    resolve(costTime);
                },
                onerror: function() {
                    resolve(Infinity); // 请求失败，耗时记为无穷大
                },
                ontimeout: function() {
                    resolve(Infinity); // 超时，耗时记为无穷大
                }
            });
        });
    }

    /**
     * 批量测速所有加速域名
     */
    async function batchSpeedTest() {
        console.log('开始测速加速域名...');
        // 清空旧结果
        speedTestResults = {};

        // 并行测速所有域名
        const testPromises = ACCELERATE_DOMAINS.map(async (domain) => {
            const costTime = await testSingleDomainSpeed(domain);
            speedTestResults[domain] = costTime;
            // 更新面板中该域名的状态
            updatePanelStatus(domain, costTime);
            console.log(`测速结果 - ${domain}: ${costTime === Infinity ? '超时/失败' : costTime + 'ms'}`);
        });

        // 等待所有测速完成
        await Promise.all(testPromises);

        // 筛选出可用的域名（耗时不是无穷大）
        const availableDomains = Object.entries(speedTestResults).filter(([_, cost]) => cost !== Infinity);

        if (availableDomains.length === 0) {
            console.warn('所有加速域名测速失败，使用第一个默认域名');
            fastestDomain = ACCELERATE_DOMAINS[0];
            updateFastestDomain();
            return;
        }

        // 找出最快的域名（耗时最小）
        availableDomains.sort((a, b) => a[1] - b[1]);
        fastestDomain = availableDomains[0][0];
        console.log(`测速完成，最快的加速域名：${fastestDomain}（耗时：${availableDomains[0][1]}ms）`);

        // 更新面板中的最快域名
        updateFastestDomain();
    }

    /**
     * 转换下载链接为最快加速域名的链接
     * @param {string} rawUrl 原始GitHub下载链接
     * @returns {string} 加速后的链接
     */
    function convertToFastestUrl(rawUrl) {
        // 过滤无效链接
        if (!rawUrl || !rawUrl.startsWith('https://github.com/')) {
            return rawUrl;
        }
        // 使用最快的域名拼接
        return fastestDomain + rawUrl;
    }

    /**
     * 替换页面中所有GitHub下载链接
     */
    function replaceDownloadLinks() {
        // 匹配GitHub常见的下载链接选择器
        const linkSelectors = [
            'a[href*="/archive/refs/tags/"]', // 标签下载链接
            'a[href*="/archive/refs/heads/"]', // 分支源码下载
            'a[href*="/releases/download/"]', // Release下载链接
            '.d-flex a[href$=".zip"]', // 源码ZIP下载
            '.d-flex a[href$=".tar.gz"]' // 源码tar.gz下载
        ];

        // 遍历所有匹配的链接
        linkSelectors.forEach(selector => {
            document.querySelectorAll(selector).forEach(link => {
                const originalHref = link.href;
                const accelerateHref = convertToFastestUrl(originalHref);
                // 替换链接地址
                link.href = accelerateHref;
                // 提示信息
                link.title = `加速下载（最快域名：${fastestDomain}）：${originalHref}`;
                link.style.color = '#2ea44f'; // GitHub绿色，区分原链接
            });
        });
    }

    // ===================== 执行流程 =====================
    // 1. 先创建测速面板
    createSpeedPanel();
    // 2. 执行批量测速
    batchSpeedTest().then(() => {
        // 3. 测速完成后，替换当前页面的下载链接
        replaceDownloadLinks();

        // 4. 监听页面动态加载（处理异步加载的链接）
        const observer = new MutationObserver((mutations) => {
            mutations.forEach(mutation => {
                if (mutation.addedNodes.length > 0) {
                    replaceDownloadLinks();
                }
            });
        });

        observer.observe(document.body, {
            childList: true,
            subtree: true
        });
    });

})();