# 诊断 v2 样本

以下是扩展单测中 happy-dom 模拟实时采集与批注快照实际生成的 summary，不是真实浏览器端到端采集。

## live 样本

症状：cannot click（target.selector: #target）。原因线索：目标指针事件被禁用（targetPointerEvents: none；target.selector: #target）；命中点被其他元素覆盖（hitTest.covered: true；hitChain: #cover，z-index: ）。

## partial 样本

症状：cannot click（target.selector: #target）。原因证据不足，尚不能定性。缺少证据：pageUrl、targetPointerEvents、hierarchy、hitTest、hitChain、viewport.width、viewport.height、viewport.dpr、viewport.devicePixelRatio、viewport.scale、viewport.scrollX、viewport.scrollY、pageErrors、networkFailures；原因见 missing。
