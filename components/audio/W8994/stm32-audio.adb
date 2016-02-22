with Ada.Interrupts.Names;

with STM32_SVD.RCC; use STM32_SVD.RCC;
with STM32_SVD.SAI; use STM32_SVD.SAI;

with STM32.Device;  use STM32.Device;
with STM32.Board;   use STM32.Board;
with STM32.GPIO;    use STM32.GPIO;
with STM32.DMA;     use STM32.DMA;
with STM32.I2C;     use STM32.I2C;
with STM32.SAI;     use STM32.SAI;

with WM8994;

with Ada.Text_IO;

package body STM32.Audio is

   procedure Set_Audio_Clock (Freq : Audio_Frequency);
   procedure Initialize_Pins;
   procedure Initialize_SAI_Out (Freq : Audio_Frequency);
   procedure Initialize_Audio_I2C;
   procedure I2C_Write (Reg : Half_Word; Value : Half_Word);
   function I2C_Read (Reg : Half_Word) return Half_Word;

   package Driver is new WM8994 (IO_Write => I2C_Write, IO_Read => I2C_Read);

   --  AUDIO OUT
   SAI_Out         : SAI_Controller renames SAI_2;
   SAI_Out_Block   : SAI_Block renames Block_A;
   DMA_Out         : STM32.DMA.DMA_Controller renames DMA_2;
   DMA_Out_Stream  : DMA_Stream_Selector renames Stream_4;
   DMA_Out_Channel : DMA_Channel_Selector renames Channel_3;

   --  AUDIO IN
--     SAI_In          : SAI_Controller renames SAI_2;
--     SAI_In_Block    : SAI_Block renames Block_B;
--     DMA_In          : STM32.DMA.DMA_Controller renames DMA_2;
--     DMA_In_Sream    : DMA_Stream_Selector renames Stream_7;
--     DMA_In_Channel  : DMA_Channel_Selector renames Channel_0;

   --  Communication with the Audio chip
   Audio_I2C_Addr  : constant Byte := 16#34#;

   protected DMA_Interrupt_Handler is
      pragma Interrupt_Priority;
      procedure Set_DMA_Half_Complete_CB (CB : DMA_Half_Complete_CB);
      procedure Set_DMA_Error_CB (CB : DMA_Error_CB);
      procedure Set_DMA_Transfer_Complete_CB (CB : DMA_Transfer_Complete_CB);
   private
      procedure Interrupt;
      pragma Attach_Handler (Interrupt, Ada.Interrupts.Names.DMA2_Stream4_Interrupt);
      HC_CB  : DMA_Half_Complete_CB := null;
      TC_CB  : DMA_Transfer_Complete_CB := null;
      Err_CB : DMA_Error_CB := null;
   end DMA_Interrupt_Handler;

   protected body DMA_Interrupt_Handler
   is

      ------------------------------
      -- Set_DMA_Half_Complete_CB --
      ------------------------------

      procedure Set_DMA_Half_Complete_CB (CB : DMA_Half_Complete_CB)
      is
      begin
         HC_CB := CB;
      end Set_DMA_Half_Complete_CB;

      procedure Set_DMA_Error_CB (CB : DMA_Error_CB)
      is
      begin
         Err_CB := CB;
      end Set_DMA_Error_CB;

      procedure Set_DMA_Transfer_Complete_CB (CB : DMA_Transfer_Complete_CB)
      is
      begin
         TC_CB := CB;
      end Set_DMA_Transfer_Complete_CB;

      ---------------
      -- Interrupt --
      ---------------

      procedure Interrupt
      is
      begin
         if STM32.DMA.Status (DMA_Out,
                              DMA_Out_Stream,
                              Half_Transfer_Complete_Indicated)
         then
            STM32.DMA.Clear_Status
              (DMA_Out, DMA_Out_Stream, Half_Transfer_Complete_Indicated);
            if HC_CB /= null then
               HC_CB.all;
            end if;
         end if;

         if STM32.DMA.Status (DMA_Out,
                              DMA_Out_Stream,
                              Transfer_Complete_Indicated)
         then
            STM32.DMA.Clear_Status
              (DMA_Out, DMA_Out_Stream, Transfer_Complete_Indicated);
            if TC_CB /= null then
               TC_CB.all;
            end if;
         end if;

         if STM32.DMA.Status (DMA_Out,
                              DMA_Out_Stream,
                              Direct_Mode_Error_Indicated)
         then
            STM32.DMA.Clear_Status
              (DMA_Out, DMA_Out_Stream, Direct_Mode_Error_Indicated);
            if Err_CB /= null then
               Err_CB (Direct_Mode_Error);
            end if;
         end if;

         if STM32.DMA.Status (DMA_Out,
                              DMA_Out_Stream,
                              Transfer_Error_Indicated)
         then
            STM32.DMA.Clear_Status
              (DMA_Out, DMA_Out_Stream, Transfer_Error_Indicated);
            if Err_CB /= null then
               Err_CB (Transfer_Error);
            end if;
         end if;
      end Interrupt;
   end DMA_Interrupt_Handler;

   ---------------------
   -- Set_Audio_Clock --
   ---------------------

   procedure Set_Audio_Clock (Freq : Audio_Frequency)
   is
   begin
      --  Two groups of frequencies: the 44kHz family and the 48kHz family
      --  The Actual audio frequency is calculated then with the following
      --  formula:
      --  Master_Clock = 256 * FS = SAI_CK / Master_Clock_Divider
      --  We need to find a value of SAI_CK that allows such integer master
      --  clock divider
      case Freq is
         when Audio_Freq_11kHz | Audio_Freq_22kHz | Audio_Freq_44kHz =>
            --  HSE/PLLM = 1MHz = PLLI2S VCO Input
            Configure_SAI_I2S_Clock
              (SAI_Out,
               PLLI2SN    => 429,  --  VCO Output = 429MHz
               PLLI2SQ    => 2,    --  SAI Clk(First level) = 214.5 MHz
               PLLI2SDIVQ => 19);  --  I2S Clk = 215.4 / 19 = 11.289 MHz

         when Audio_Freq_8kHz | Audio_Freq_16kHz | Audio_Freq_48kHz | Audio_Freq_96kHz =>
            Configure_SAI_I2S_Clock
              (SAI_Out,
               PLLI2SN    => 344,  --  VCO Output = 344MHz
               PLLI2SQ    => 7,    --  SAI Clk(First level) = 49.142 MHz
               PLLI2SDIVQ => 1);  --  I2S Clk = 49.142 MHz
      end case;
   end Set_Audio_Clock;

   ---------------------
   -- Initialize_Pins --
   ---------------------

   procedure Initialize_Pins
   is
      SAI_Pins : constant GPIO_Points :=
                   (SAI2_MCLK_A, SAI2_FS_A, SAI2_SD_A, SAI2_SCK_A);
   begin
      Enable_Clock (SAI_2);
      Enable_Clock (SAI_Pins);

      Configure_IO
        (SAI_Pins,
         (Mode        => Mode_AF,
          Output_Type => Push_Pull,
          Speed       => Speed_High,
          Resistors   => Floating));
      Configure_Alternate_Function
        (SAI_Pins, GPIO_AF_SAI2);

      Enable_Clock (DMA_Out);

      --  Configure the DMA channel to the SAI peripheral
      Disable (DMA_Out, DMA_Out_Stream);
      Configure
        (DMA_Out,
         DMA_Out_Stream,
         (Channel                      => DMA_Out_Channel,
          Direction                    => Memory_To_Peripheral,
          Increment_Peripheral_Address => False,
          Increment_Memory_Address     => True,
          Peripheral_Data_Format       => HalfWords,
          Memory_Data_Format           => HalfWords,
          Operation_Mode               => Circular_Mode,
          Priority                     => Priority_High,
          FIFO_Enabled                 => True,
          FIFO_Threshold               => FIFO_Threshold_Full_Configuration,
          Memory_Burst_Size            => Memory_Burst_Single,
          Peripheral_Burst_Size        => Peripheral_Burst_Single));
      Clear_All_Status (DMA_Out, DMA_Out_Stream);
   end Initialize_Pins;

   ------------------------
   -- Initialize_SAI_Out --
   ------------------------

   procedure Initialize_SAI_Out (Freq : Audio_Frequency)
   is
   begin
      STM32.SAI.Disable (SAI_Out, SAI_Out_Block);
      STM32.SAI.Configure_Audio_Block
        (SAI_Out,
         SAI_Out_Block,
         Frequency       => Audio_Frequency'Enum_Rep (Freq),
         Stereo_Mode     => Stereo,
         Mode            => Master_Transmitter,
         MCD_Enabled     => True,
         Protocol        => Free_Protocol,
         Data_Size       => Data_16b,
         Endianness      => Data_MSB_First,
         Clock_Strobing  => Clock_Strobing_Rising_Edge,
         Synchronization => Asynchronous_Mode,
         Output_Drive    => Drive_Immediate,
         FIFO_Threshold  => FIFO_1_Quarter_Full);
      STM32.SAI.Configure_Block_Frame
        (SAI_Out,
         SAI_Out_Block,
         Frame_Length => 64,
         Frame_Active => 32,
         Frame_Sync   => FS_Frame_And_Channel_Identification,
         FS_Polarity  => FS_Active_Low,
         FS_Offset    => Before_First_Bit);
      STM32.SAI.Configure_Block_Slot
        (SAI_Out,
         SAI_Out_Block,
         First_Bit_Offset => 0,
         Slot_Size        => Data_Size,
         Number_Of_Slots  => 4,
         Enabled_Slots    => Slot_0 or Slot_2);
      STM32.SAI.Enable (SAI_Out, SAI_Out_Block);
   end Initialize_SAI_Out;

   --------------------------
   -- Initialize_Audio_I2C --
   --------------------------

   procedure Initialize_Audio_I2C
   is
   begin
      Initialize_I2C_GPIO (Audio_I2C);
      Configure_I2C (Audio_I2C);
   end Initialize_Audio_I2C;

   ---------------
   -- I2C_Write --
   ---------------

   procedure I2C_Write (Reg : Half_Word; Value : Half_Word)
   is
      Status : I2C_Status with Unreferenced;
      Data   : I2C_Data (1 .. 2);
      Check  : Short;
   begin
      --  Device is MSB first
      Data (1) := Byte (Shift_Right (Value and 16#FF00#, 8));
      Data (2) := Byte (Value and 16#FF#);

      STM32.I2C.Mem_Write
        (Audio_I2C,
         Addr          => UInt10 (Audio_I2C_Addr),
         Mem_Addr      => Reg,
         Mem_Addr_Size => Memory_Size_16b,
         Data          => Data,
         Status        => Status);

      if Reg /= 0 then
         Check := I2C_Read (Reg);
         if Check /= Value then
            Ada.Text_IO.Put_Line
              ("Written " & Value'Img & " got " & Check'Img & " for reg " & Reg'Img);
         end if;
      end if;
   end I2C_Write;

   --------------
   -- I2C_Read --
   --------------

   function I2C_Read (Reg : Half_Word) return Half_Word
   is
      Status : I2C_Status;
      Data   : I2C_Data (1 .. 2);
      Ret    : Half_Word;
   begin
      STM32.I2C.Mem_Read
        (Audio_I2C,
         Addr          => UInt10 (Audio_I2C_Addr),
         Mem_Addr      => Reg,
         Mem_Addr_Size => Memory_Size_16b,
         Data          => Data,
         Status        => Status);
      Ret := Shift_Left (Half_Word (Data (1)), 8) or Half_Word (Data (2));

      return Ret;
   end I2C_Read;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize_Audio_Out
     (Volume    : Audio_Volume;
      Frequency : Audio_Frequency)
   is
   begin
      STM32.SAI.Deinitialize (SAI_Out, SAI_Out_Block);

      Set_Audio_Clock (Frequency);

      --  Initialize the SAI
      Initialize_Pins;
      Initialize_SAI_Out (Frequency);

      --  Initialize the I2C Port to send commands to the driver
      Initialize_Audio_I2C;

      if Driver.Read_ID /= Driver.WM8994_ID then
         raise Constraint_Error with "Invalid ID received from the Audio Code";
      end if;

      Driver.Reset;
      Driver.Init
        (Input     => Driver.No_Input,
         Output    => Driver.Auto,
         Volume    => Byte (Volume),
         Frequency =>
           Driver.Audio_Frequency'Enum_Val
             (Audio_Frequency'Enum_Rep (Frequency)));
   end Initialize_Audio_Out;

   --------------------------------
   -- Set_Half_Complete_Callback --
   --------------------------------

   procedure Set_Half_Complete_Callback
     (Callback : DMA_Half_Complete_CB)
   is
   begin
      DMA_Interrupt_Handler.Set_DMA_Half_Complete_CB (Callback);
   end Set_Half_Complete_Callback;

   ------------------------------------
   -- Set_Transfer_Complete_Callback --
   ------------------------------------

   procedure Set_Transfer_Complete_Callback
     (Callback : DMA_Transfer_Complete_CB)
   is
   begin
      DMA_Interrupt_Handler.Set_DMA_Transfer_Complete_CB (Callback);
   end Set_Transfer_Complete_Callback;

   ------------------------
   -- Set_Error_Callback --
   ------------------------

   procedure Set_Error_Callback
     (Callback : DMA_Error_CB)
   is
   begin
      DMA_Interrupt_Handler.Set_DMA_Error_CB (Callback);
   end Set_Error_Callback;

   ----------
   -- Play --
   ----------

   procedure Play
     (Buffer : Audio_Buffer)
   is
   begin
      Driver.Play;

      Start_Transfer_with_Interrupts
        (Unit        => DMA_Out,
         Stream      => DMA_Out_Stream,
         Source      => Buffer (Buffer'First)'Address,
         Destination => SAI_Out.ADR'Address,
         Data_Count  => Buffer'Length);
--        STM32.DMA.Disable (DMA_Out, DMA_Out_Stream);
--        STM32.DMA.Configure_Data_Flow
--          (Unit        => DMA_Out,
--           Stream      => DMA_Out_Stream,
--           Source      => Buffer (Buffer'First)'Address,
--           Destination => SAI_Out.ADR'Address,
--           Data_Count  => Buffer'Length);
--        STM32.DMA.Enable_Interrupt
--          (DMA_Out, DMA_Out_Stream, Direct_Mode_Error_Interrupt);
--        STM32.DMA.Enable_Interrupt
--          (DMA_Out, DMA_Out_Stream, Transfer_Error_Interrupt);
--        STM32.DMA.Enable_Interrupt
--          (DMA_Out, DMA_Out_Stream, Half_Transfer_Complete_Interrupt);
--        STM32.DMA.Enable_Interrupt
--          (DMA_Out, DMA_Out_Stream, Transfer_Complete_Interrupt);
--        STM32.DMA.Enable_Interrupt
--          (DMA_Out, DMA_Out_Stream, FIFO_Error_Interrupt);
--
--        STM32.DMA.Enable (DMA_Out, DMA_Out_Stream);

      Enable_DMA (SAI_Out, SAI_Out_Block);

      if not Enabled (SAI_Out, SAI_Out_Block) then
         Enable (SAI_Out, SAI_Out_Block);
      end if;
   end Play;

   -------------------
   -- Change_Buffer --
   -------------------

   procedure Change_Buffer
     (Buffer : Audio_Buffer)
   is
   begin
      null;
   end Change_Buffer;

   -----------
   -- Pause --
   -----------

   procedure Pause is
   begin
      Driver.Pause;
      STM32.DMA.Disable (DMA_Out, DMA_Out_Stream);
   end Pause;

   procedure Resume
   is
   begin
      null;
   end Resume;

   procedure Stop
   is
   begin
      null;
   end Stop;

   ----------------
   -- Set_Volume --
   ----------------

   procedure Set_Volume
     (Volume : Audio_Volume)
   is
   begin
      Driver.Set_Volume (Byte (Volume));
   end Set_Volume;

   -------------------
   -- Set_Frequency --
   -------------------

   procedure Set_Frequency
     (Frequency : Audio_Frequency)
   is
   begin
      Set_Audio_Clock (Frequency);
      STM32.SAI.Disable (SAI_Out, SAI_Out_Block);
      Initialize_SAI_Out (Frequency);
      STM32.SAI.Enable (SAI_Out, SAI_Out_Block);
   end Set_Frequency;

end STM32.Audio;
