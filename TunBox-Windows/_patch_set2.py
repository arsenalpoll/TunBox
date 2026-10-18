import io, re

p = 'src/TunBox.App/MainWindow.xaml'
s = io.open(p, encoding='utf-8').read()
applied = []

# ── A) 应用 expander → 常用卡(外露,无折叠),勾选框改开关 ──
start = s.index('                    <Expander IsExpanded="{Binding GeneralExpanded, Mode=TwoWay}"')
end = s.index('                <Border Style="{StaticResource Card}">', start)   # 网络配置卡开头
app_block = s[start:end]

# 抽出 expander 内层 StackPanel 内容
inner_start = app_block.index('<StackPanel Margin="0,8,0,0">') + len('<StackPanel Margin="0,8,0,0">\n')
inner_end = app_block.rindex('</StackPanel>\n                    </Expander>')
inner = app_block[inner_start:inner_end]

# 勾选框 → 开关行(即时生效)
inner = inner.replace('''                            <CheckBox Content="{DynamicResource L.Set.AutoStart}" Margin="0,12,0,0" IsChecked="{Binding AutoStartOn}"/>
                            <CheckBox Content="{DynamicResource L.Set.SilentStart}" Margin="0,8,0,0"
                                      IsChecked="{Binding StartMinimizedOn}"
                                      ToolTip="{DynamicResource L.Set.SilentStartTip}"/>''',
'''                            <Grid Margin="0,14,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Grid Grid.Column="0" Margin="0,0,16,0">
                                    <TextBlock Text="{DynamicResource L.Set.AutoStart}" VerticalAlignment="Center"
                                               Foreground="{StaticResource TextMain}"/>
                                    <ToggleButton HorizontalAlignment="Right" IsChecked="{Binding AutoStartOn}"
                                                  Style="{StaticResource Switch}"/>
                                </Grid>
                                <Grid Grid.Column="1">
                                    <TextBlock Text="{DynamicResource L.Set.SilentStart}" VerticalAlignment="Center"
                                               Foreground="{StaticResource TextMain}"
                                               ToolTip="{DynamicResource L.Set.SilentStartTip}"/>
                                    <ToggleButton HorizontalAlignment="Right" IsChecked="{Binding StartMinimizedOn}"
                                                  Style="{StaticResource Switch}"
                                                  ToolTip="{DynamicResource L.Set.SilentStartTip}"/>
                                </Grid>
                            </Grid>''')

common_card = '''                <!-- 常用:一眼可见,不折叠 -->
                <Border Style="{StaticResource Card}">
                    <StackPanel>
                        <TextBlock Text="{DynamicResource L.Set.Section.Common}" Style="{StaticResource SectionTitle}"/>
''' + inner + '''
                    </StackPanel>
                </Border>

'''
s = s[:start] + common_card + s[end:]
applied.append('常用卡')

# ── B) Hosts 卡 + 覆写卡 → 合并为「覆写与 Hosts」折叠卡 ──
hosts_start = s.index('                <Border Style="{StaticResource Card}">\n                    <StackPanel>\n                        <TextBlock Text="{DynamicResource L.Tools.Hosts}"')
override_start = s.index('                <Border Style="{StaticResource Card}">', hosts_start)
log_start = s.index('                <Border Style="{StaticResource Card}">', override_start)
hosts_block = s[hosts_start:override_start]
override_block = s[override_start:log_start]

hosts_inner = hosts_block[hosts_block.index('<StackPanel>') : hosts_block.rindex('</StackPanel>')]
override_inner = override_block[override_block.index('<StackPanel>') : override_block.rindex('</StackPanel>')]

merged = '''                <!-- 覆写与 Hosts:高级项,收纳 -->
                <Border Style="{StaticResource Card}">
                    <Expander IsExpanded="{Binding OverrideHostsExpanded, Mode=TwoWay}"
                              Header="{DynamicResource L.Set.Section.OverrideHosts}" FontSize="16" FontWeight="SemiBold"
                              Foreground="{StaticResource TextMain}">
                        <StackPanel Margin="0,8,0,0">
''' + hosts_inner + '''
''' + override_inner + '''
                        </StackPanel>
                    </Expander>
                </Border>

'''
s = s[:hosts_start] + merged + s[log_start:]
applied.append('覆写与Hosts折叠')

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('applied:', applied)

# ── 字典键 ──
zh = 'src/TunBox.App/Assets/Lang/zh.xaml'
s = io.open(zh, encoding='utf-8').read()
if 'L.Set.Section.Common' not in s:
    s = s.replace('<sys:String x:Key="L.Set.Section.App">应用</sys:String>',
'''    <sys:String x:Key="L.Set.Section.Common">常用</sys:String>
    <sys:String x:Key="L.Set.Section.OverrideHosts">覆写与 Hosts</sys:String>
    <sys:String x:Key="L.Set.Section.App">应用</sys:String>''', 1)
    io.open(zh, 'w', encoding='utf-8', newline='').write(s)
en = 'src/TunBox.App/Assets/Lang/en.xaml'
s = io.open(en, encoding='utf-8').read()
if 'L.Set.Section.Common' not in s:
    s = s.replace('<sys:String x:Key="L.Set.Section.App">App</sys:String>',
'''    <sys:String x:Key="L.Set.Section.Common">Common</sys:String>
    <sys:String x:Key="L.Set.Section.OverrideHosts">Override &amp; Hosts</sys:String>
    <sys:String x:Key="L.Set.Section.App">App</sys:String>''', 1)
    io.open(en, 'w', encoding='utf-8', newline='').write(s)
print('lang ok')
