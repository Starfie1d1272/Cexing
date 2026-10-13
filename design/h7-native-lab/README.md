# HarmonyOS 原生材质独立试验

这个小工程只包含Navigation、Tabs/HdsTabs、系统Dialog/ActionSheet/Sheet、Toggle、Select与可滚动合成内容。没有VPN、订阅、Controller或网络权限。包标识`org.example.arkts.materiallab`仅属于独立试验，避免覆盖生产应用；生产名称、图标与身份没有改变。

从仓库根初始化官方CLT/JDK/Node环境，执行：

```bash
bash design/h7-native-lab/build.sh default
bash design/h7-native-lab/build.sh enable
bash design/h7-native-lab/build.sh disable
```

脚本在临时工程修改metadata并编译，产物存入忽略的`.h7-lab-output/`，不安装、不操作手机、不改生产manifest。三个包是同一独立试验的不同应用级状态，用于依次安装比较；不能同时安装为三个不同应用。设备安装与系统设置由本地测试Agent执行。

界面显示实际`getMaterialInfo().state`、硬件支持及全局材质等级。普通Tabs可选五种ImmersiveStyle；HdsTabs采用ADAPTIVE type/level及温控。测试同样包括固定主动作、长内容滚动、二级页返回和半模态。HDS试验需API23/HDS Core；普通沉浸材质需API26。

真机需要分别记录系统沉浸光感强/均衡/弱、浅深主题、实际窗口宽高vp、截图像素、系统字号、源码及签名包摘要。打开不同系统控件比较DEFAULT/ENABLE；DISABLE作为负对照。用户系统强度不等于设备MaterialLevel，也不是这几个包的metadata。

已通过SDK编译，不表示光感已在设备生效。没有Chromium页面或截图替代原生效果；独立工程不随生产HAP打包。
