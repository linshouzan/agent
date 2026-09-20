//////////////////////////////////////////////////////////////////
// 文件名：PrivateQAManager.swift
// 文件说明：适用于 macOS 14+ 的私域知识库管理器与视图面板
// 核心解构架构拓扑 (Domain-Driven Architecture):
// 1. 等宽弹性布局、KV 关系强化、支持多行键名
//////////////////////////////////////////////////////////////////

import SwiftUI

struct PrivateQAManager {
    static let shared = PrivateQAManager()
    
    // MARK: - 内部数据操作逻辑
    
    func updatePrivateQA(agentName: String?, keyword: String, content: String) {
        var profiles = ConfigManager.shared.app.agentProfiles
        let activeAgentID = AiChatStore.shared.selectedAgentID
        let targetID: UUID?
        
        if let name = agentName, !name.isEmpty {
            targetID = profiles.first(where: { $0.name.lowercased() == name.lowercased() })?.id
        } else {
            targetID = activeAgentID
        }
        
        guard let id = targetID, let idx = profiles.firstIndex(where: { $0.id == id }) else {
            LogManager.shared.warning("⚠️ [IPC 通信] 更新 QA 失败：未找到指定的智能体")
            return
        }
        
        let newContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 智能内容合并逻辑 (局部覆盖/追加)
        if let qaIdx = profiles[idx].privateQA.firstIndex(where: { $0.keyword == keyword }) {
            let oldContent = profiles[idx].privateQA[qaIdx].content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 执行智能合并引擎
            let mergedContent = performSmartMerge(oldContent: oldContent, newContent: newContent)
            
            profiles[idx].privateQA[qaIdx].content = mergedContent
            profiles[idx].privateQA[qaIdx].isEnabled = true // 外部更新时强制设为启用
            
            LogManager.shared.success("📡 [IPC 通信] 私域知识已智能更新", detail: "键: \(keyword) | 动作: 局部覆盖/追加")
        } else {
            let newPair = PrivateQAPair(keyword: keyword, content: newContent)
            profiles[idx].privateQA.insert(newPair, at: 0)
            
            LogManager.shared.success("📡 [IPC 通信] 私域知识已新建", detail: "键: \(keyword)")
        }
        
        // 持久化并通知内存更新
        ConfigManager.shared.app.agentProfiles = profiles
        ConfigManager.shared.saveConfig()
        
        // 发送全局广播，通知各处的 UI 和会话引擎刷新内存 (复用上一步骤的广播逻辑)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("AgentProfilesExternallyUpdated"), object: nil)
        }
    }
    
    // MARK: - 智能合并与局部覆盖引擎
    
    /// 根据新传入内容的特征，智能决定是覆盖指定章节、追加还是全量覆盖
    private func performSmartMerge(oldContent: String, newContent: String) -> String {
        if oldContent.isEmpty { return newContent }
        if newContent.isEmpty { return oldContent }
        
        let newLines = newContent.components(separatedBy: .newlines)
        
        // 1. 提取新内容的第一个“有效文本行”作为特征锚点
        guard let firstValidLine = newLines.first(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 智能过滤掉 markdown 代码块标记或分割线等无意义首行
            return !trimmed.isEmpty && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("---") && !trimmed.hasPrefix("===")
        }) else {
            // 如果新内容全是代码块或无特征文本，则默认退化为追加策略
            return oldContent + "\n\n" + newContent
        }
        
        // 2. 提取并清理锚点文本 (剥离 Markdown 标题符以便精准匹配)
        let markdownSymbols = CharacterSet(charactersIn: "#-* ")
        let anchor = firstValidLine.trimmingCharacters(in: CharacterSet.whitespaces.union(markdownSymbols))
        guard !anchor.isEmpty else { return oldContent + "\n\n" + newContent }
        
        let oldLines = oldContent.components(separatedBy: .newlines)
        var matchIndex: Int? = nil
        
        // 3. 在旧内容中自上而下扫描锚点
        for (index, line) in oldLines.enumerated() {
            let cleanOldLine = line.trimmingCharacters(in: CharacterSet.whitespaces.union(markdownSymbols))
            
            // 如果旧内容中的某一行与新内容的首行核心文本一致（例如都叫 "第二章" 或 "核心逻辑更新"）
            if cleanOldLine == anchor {
                matchIndex = index
                break
            }
        }
        
        // 4. 执行切片合并逻辑
        if let idx = matchIndex {
            // 命中：截断旧内容，保留到该章节之上。然后拼接整个新内容。
            let preservedOld = oldLines[0..<idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if preservedOld.isEmpty {
                return newContent // 如果截断后前面没东西了，说明是第一章被重写，等同于全量覆盖
            } else {
                return preservedOld + "\n\n" + newContent
            }
        } else {
            // 未命中：全新的内容（例如首次写入 第三章），执行安全追加
            return oldContent + "\n\n" + newContent
        }
    }
    
    func readPrivateQA(agentName: String?, keyword: String) -> String? {
        let profiles = ConfigManager.shared.app.agentProfiles
        let activeAgentID = AiChatStore.shared.selectedAgentID
        let targetID: UUID?
        
        if let name = agentName, !name.isEmpty {
            targetID = profiles.first(where: { $0.name.lowercased() == name.lowercased() })?.id
        } else {
            targetID = activeAgentID
        }
        
        guard let id = targetID, let profile = profiles.first(where: { $0.id == id }) else { return nil }
        
        // 查找精确匹配的 keyword 并确认其开启状态
        if let pair = profile.privateQA.first(where: { $0.keyword == keyword }), pair.isEnabled {
            return pair.content
        }
        
        return nil
    }
}

struct PrivateQAManagerSheet: View {
    @Binding var qaList: [PrivateQAPair]
    var onClose: () -> Void
    
    @State private var newKeyword: String = ""
    @State private var newContent: String = ""
    
    // 用于控制编辑弹窗的状态
    @State private var editingPair: PrivateQAPair? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // --- 顶部 Header ---
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.book.closed.fill").foregroundColor(.purple)
                        Text("私域泛 KV 知识库").font(.system(size: 16, weight: .bold))
                    }
                    Text("Value 支持多行长文本。列表自动折叠为 3 行，点击编辑可修改全文。").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(20).background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // --- 多行录入区 ---
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    // Key 输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("键 (Key / 短句)").font(.system(size: 11, weight: .bold)).foregroundColor(.purple)
                        TextField("如：核心开发规范", text: $newKeyword)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 200)
                    
                    // Value 多行输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("详细定义 (Value)").font(.system(size: 11, weight: .bold)).foregroundColor(.blue)
                        
                        // 包装 TextEditor 使其看起来像 macOS 原生输入框
                        TextEditor(text: $newContent)
                            .font(.system(size: 13))
                            .frame(height: 70) // 固定一个舒适的初始高度
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                            )
                    }
                    
                    // 添加按钮
                    Button(action: addNewPair) {
                        VStack(spacing: 4) {
                            Image(systemName: "plus.app.fill").font(.system(size: 24))
                            Text("添加").font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain).foregroundColor(.purple).padding(.top, 24)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
                .background(Color.purple.opacity(0.05))
                .cornerRadius(10)
            }
            .padding(16)
            
            // --- 列表区 ---
            List {
                if qaList.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "archivebox").font(.system(size: 32)).foregroundStyle(.tertiary)
                        Text("暂无数据。尝试录入多行规则或知识。").font(.system(size: 13)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .listRowBackground(Color.clear)
                }
                
                ForEach($qaList) { $qa in
                    KVRowItem(qa: $qa, onEdit: {
                        editingPair = qa // 唤起编辑弹窗
                    }, onDelete: {
                        withAnimation { qaList.removeAll { $0.id == qa.id } }
                    })
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
            .listStyle(.plain)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 800, height: 600)
        // 挂载编辑子窗口
        .sheet(item: $editingPair) { pair in
            PrivateQAEditView(pair: pair, onSave: { updatedPair in
                if let idx = qaList.firstIndex(where: { $0.id == updatedPair.id }) {
                    qaList[idx] = updatedPair
                }
                editingPair = nil
            }, onCancel: {
                editingPair = nil
            })
        }
    }
    
    private func addNewPair() {
        let cleanK = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanV = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanK.isEmpty && !cleanV.isEmpty {
            withAnimation(.spring()) {
                qaList.insert(PrivateQAPair(keyword: cleanK, content: cleanV), at: 0)
                newKeyword = ""
                newContent = ""
            }
        }
    }
}

// 专为 KV 设计的行组件
struct KVRowItem: View {
    @Binding var qa: PrivateQAPair
    var onEdit: () -> Void
    var onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // 左侧状态色带
            Rectangle()
                .fill(qa.isEnabled ? Color.purple : Color.gray.opacity(0.4))
                .frame(width: 4)
            
            VStack(alignment: .leading, spacing: 8) {
                // 上半部分：Key 与 操作按钮
                HStack(alignment: .center) {
                    Text(qa.keyword)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(qa.isEnabled ? .purple : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.purple.opacity(qa.isEnabled ? 0.1 : 0.05))
                        .cornerRadius(6)
                    
                    Spacer()
                    
                    HStack(spacing: 14) {
                        Toggle("", isOn: $qa.isEnabled).toggleStyle(.switch).controlSize(.small)
                        
                        Button(action: onEdit) {
                            Image(systemName: "square.and.pencil").foregroundColor(.blue)
                        }.buttonStyle(.plain).help("编辑内容")
                        
                        Button(action: onDelete) {
                            Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                        }.buttonStyle(.plain).help("删除该项")
                    }
                }
                
                // 下半部分：Value 多行预览 (核心逻辑)
                Text(qa.content)
                    .font(.system(size: 13))
                    .lineSpacing(4) // 增加行距提升阅读体验
                    .foregroundColor(qa.isEnabled ? .primary : .secondary)
                    .lineLimit(3) // 严格限制前 3 行
                    .truncationMode(.tail) // 尾部显示省略号
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
            }
            .padding(12)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.05), lineWidth: 1))
        // 支持双击快速触发编辑
        .onTapGesture(count: 2) {
            onEdit()
        }
    }
}

// 专属 KV 编辑弹窗
struct PrivateQAEditView: View {
    @State var pair: PrivateQAPair
    var onSave: (PrivateQAPair) -> Void
    var onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("编辑知识点")
                .font(.system(size: 14, weight: .bold))
                .padding(.vertical, 16)
            
            Divider()
            
            // 表单区
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("键 (Key)").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    TextField("", text: $pair.keyword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .bold))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("详细定义 (Value)").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    
                    TextEditor(text: $pair.content)
                        .font(.system(size: 13, design: .monospaced)) // 等宽字体更适合泛 KV
                        .frame(minHeight: 200)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
                }
            }
            .padding(20)
            
            Divider()
            
            // 底部操作区
            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction) // 按 ESC 取消
                Spacer()
                Button("保存修改") {
                    // 清理可能误输入的收尾空白符
                    pair.keyword = pair.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    pair.content = pair.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(pair)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction) // 按 回车 保存 (如果焦点不在 TextEditor 内)
                .disabled(pair.keyword.isEmpty || pair.content.isEmpty)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 550, height: 480)
    }
}

